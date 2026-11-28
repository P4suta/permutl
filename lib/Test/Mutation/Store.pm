package Test::Mutation::Store;
use v5.36;
use DBI                   ();
use Fcntl                 qw(:flock);
use List::Util            ();
use POSIX                 ();
use File::Basename        ();
use File::Spec            ();
use File::Temp            ();
use Hash::Util::FieldHash qw(fieldhash);
use Cpanel::JSON::XS      ();
use JSON::PP              ();
use Types::Standard       qw(ArrayRef Bool CodeRef Defined Dict HashRef InstanceOf Int Maybe Num Optional Str);
use Type::Params          qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Store::Key;
use Test::Mutation::Status;
use Test::Mutation::Tree;
use Test::Mutation::Try;
use Test::Mutation::Types  qw(Observations Reason StatusName);
use DBD::SQLite::Constants qw(SQLITE_BUSY SQLITE_NOTADB);
use Test::Mutation::Clock;

our $VERSION = '0.001';

my $JSON = Cpanel::JSON::XS->new->canonical;
fieldhash my %private;

my $FORMAT   = 5;
my $BUILD    = ArrayRef [Str];
my $LINES    = HashRef [Bool];
my $ORIGINAL = Dict [
    inputs    => Str,
    includes  => ArrayRef [Str],
    duration  => Num,
    files     => HashRef [ Dict [ traced => Bool, hits => $LINES ] ],
    breakable => HashRef [$LINES]
];
my $ORIGINALS = Dict [ build => $BUILD, tests => HashRef [$ORIGINAL] ];
my $CHANGES   = Dict [ build => $BUILD, tests => HashRef [ Maybe [$ORIGINAL] ], reset => Optional [Bool] ];
my $RECORD    = (
    Dict [
        inputs          => Str,
        path            => Optional [Str],
        source          => Optional [Str],
        status          => StatusName,
        reason          => Maybe [Reason],
        detail          => Maybe [Str],
        by              => Maybe [Str],
        tests_run       => Int,
        duration        => Num,
        code            => Maybe [Str],
        compiler_inputs => Optional [ HashRef [Str] ],
        observations    => Optional [Observations],
    ]
)->where(
    sub {
        Test::Mutation::Status::fits( $_->{status}, $_->{reason} ) && defined( $_->{path} ) == defined( $_->{source} );
    }
);

signature_for format_version => ( positional => [], returns => Int );

sub format_version () {
    return $FORMAT;
}

signature_for sample => ( positional => [ ArrayRef [Str], Str ], returns => ArrayRef [Str] );

sub sample ( $ids, $seed ) {
    my $count   = scalar @$ids;
    my $take    = List::Util::min( $count, List::Util::max( 3, POSIX::ceil( $count / 50 ) ) );
    my %rank    = map  { $_ => Test::Mutation::Store::Key::digest( $seed, $_ ) } @$ids;
    my @ordered = sort { $rank{$a} cmp $rank{$b} || $a cmp $b } @$ids;
    return [ @ordered[ 0 .. $take - 1 ] ];
}

signature_for load =>
  ( positional => [ Str, Maybe [ ArrayRef [Str] ], { default => undef } ], returns => HashRef [$RECORD] );

sub load ( $path, $ids ) {
    my $records;
    if ( $path =~ /[.]sqlite\z/ ) {
        my $db = read_database($path);
        return _stored( $db, 'verdict', $ids ) if $db;
        $records = _identified( _read( File::Spec->catfile( File::Basename::dirname($path), 'cache.json' ) ) );
    }
    else { $records = _validated( _read($path)->{mutants}, $RECORD ) }
    return $records unless defined $ids;
    return { map { $_ => $records->{$_} } grep { exists $records->{$_} } @$ids };
}

signature_for originals => ( positional => [Str], returns => $ORIGINALS );

sub originals ($path) {
    if ( $path =~ /[.]sqlite\z/ ) {
        my $db = read_database($path);
        return _originals( _read( File::Spec->catfile( File::Basename::dirname($path), 'cache.json' ) ) )
          unless $db;
        my ($build) = $db->selectrow_array("SELECT data FROM setting WHERE id = 'build'");
        return { build => _decoded( $build, $BUILD ) || [], tests => _stored( $db, 'original' ) };
    }
    return _originals( _read($path) );
}

sub _decoded ( $text, $type ) {
    return unless defined $text;
    my $parsed = Test::Mutation::Try::attempt( sub { [ $JSON->decode($text) ] } );
    return unless $parsed->{value};
    my $record = $parsed->{value}[0];
    return $type->check($record) ? $record : undef;
}

sub _stored ( $db, $table, $ids = undef ) {
    my $query = "SELECT id, data FROM $table";
    $query .= ' WHERE id IN (SELECT value FROM json_each(?))' if defined $ids;
    my $read = $db->prepare($query);
    $read->execute( defined $ids ? $JSON->encode($ids) : () );
    my %records;
    my $type = $table eq 'verdict' ? $RECORD : $ORIGINAL;
    while ( my $row = $read->fetchrow_arrayref ) {
        my $record = _decoded( $row->[1], $type );
        $records{ $row->[0] } = $record if defined $record;
    }
    return \%records;
}

signature_for path =>
  ( positional => [ InstanceOf ['Test::Mutation::Config'], Bool, { default => 1 } ], returns => Str );

sub path ( $config, $write ) {
    return File::Spec->catfile( $private{$config}, 'measurement.sqlite' ) if exists $private{$config};
    my $stored = File::Spec->catfile( File::Spec->rel2abs( $config->cache_dir, $config->root ), 'measurement.sqlite' );
    return $stored if !$write || !$config->cache || exists $config->specified->{'cache-dir'} || -w $config->root;
    my $directory = File::Temp->newdir;
    my $copy      = File::Spec->catfile( $directory, 'measurement.sqlite' );
    if ( my $db = read_database($stored) ) {
        $db->sqlite_backup_to_file($copy);
    }
    else {
        my $legacy = File::Spec->catfile( File::Basename::dirname($stored), 'cache.json' );
        database( $copy, $legacy ) if -f $legacy;
    }
    $private{$config} = $directory;
    return $copy;
}

signature_for transaction => ( positional => [ InstanceOf ['DBI::db'], CodeRef ], returns => Defined );

sub transaction ( $db, $operation ) {
    local $db->{RaiseError} = 1;
    $db->begin_work;
    my $committed = Test::Mutation::Try::attempt(
        sub {
            my $value = $operation->();
            my $saved = $db->commit;
            return $value // $saved;
        },
        'interruption'
    );
    return $committed->{value} if exists $committed->{value};
    if    ( !$db->{AutoCommit} ) { $db->rollback }
    elsif ( $db->{Driver}{Name} eq 'SQLite' && !$db->sqlite_get_autocommit ) {

        # DBI may restore AutoCommit while SQLite still holds a transaction that failed to commit.
        $db->do('ROLLBACK');
    }
    die $committed->{error};    ## no critic (ErrorHandling::RequireCarping)
}

sub _connect ( $path, $read_only = 0 ) {
    my $uri = $path;
    $uri =~ s/([%;?#])/sprintf '%%%02X', ord $1/ge;
    $uri .= '?mode=ro' if $read_only;
    my $db = DBI->connect(
        "dbi:SQLite:uri=file:$uri",
        undef, undef,
        {
            RaiseError          => 1,
            PrintError          => 0,
            AutoInactiveDestroy => 1,
            sqlite_unicode      => 1,
            HandleError         => sub ( $message, @ ) {
                Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => $message ) if $read_only;
                Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => $message );
            }
        }
    );
    $db->sqlite_busy_timeout(30_000);
    return $db;
}

sub _initialized ( $db, $path, $read_only = 0 ) {
    my $probe = Test::Mutation::Try::attempt( sub { return $db->selectrow_array('PRAGMA user_version') } );
    if ( exists $probe->{error} ) {
        die $probe->{error} unless ( ( $db->err // 0 ) & 255 ) == SQLITE_NOTADB;    ## no critic (ErrorHandling::RequireCarping)
        return 0 if $read_only;
        Test::Mutation::Error::raise(
            'file-unwritable',
            path   => $path,
            reason => 'expected a SQLite database, so rerun with --no-cache or choose another --cache-dir'
        );
    }
    my $schema = $probe->{value};
    return 1 if $schema == 1;
    Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "unsupported database schema $schema" )
      if $schema;
    return 0;
}

signature_for read_database => ( positional => [Str], returns => Maybe [ InstanceOf ['DBI::db'] ] );

sub read_database ($path) {
    return unless -f $path;
    my $db = _connect( $path, 1 );
    return _initialized( $db, $path, 1 ) ? $db : undef;
}

signature_for database =>
  ( positional => [ Str, Maybe [Str], { default => undef } ], returns => InstanceOf ['DBI::db'] );

sub database ( $path, $legacy ) {
    my $directory = File::Basename::dirname($path);
    Test::Mutation::Tree::make($directory) unless -d $directory;
    my $db = _connect($path);
    return $db if _initialized( $db, $path );
    transaction(
        $db,
        sub {
            return if _initialized( $db, $path );
            $db->do('CREATE TABLE verdict (id TEXT PRIMARY KEY, path TEXT, source TEXT, data TEXT NOT NULL)');
            $db->do('CREATE INDEX verdict_path ON verdict(path)');
            $db->do('CREATE TABLE original (id TEXT PRIMARY KEY, data TEXT NOT NULL)');
            $db->do('CREATE TABLE setting (id TEXT PRIMARY KEY, data TEXT NOT NULL)');
            $db->do(
                'CREATE TABLE measurement (run INTEGER PRIMARY KEY, project TEXT, finished REAL, anchor INTEGER, complete INTEGER)'
            );
            $db->do('CREATE INDEX measured_scope ON measurement(project, anchor, run DESC)');
            $db->do(
                'CREATE TABLE observation (run INTEGER, ordinal INTEGER, id TEXT, path TEXT, source TEXT, status TEXT, data TEXT, PRIMARY KEY(run, id))'
            );
            $db->do('CREATE INDEX observed_mutant ON observation(id, source, run)');
            $db->do('CREATE TABLE analysis (identity TEXT PRIMARY KEY, facts TEXT NOT NULL)');
            $db->do(
                'CREATE TABLE candidate (analysis TEXT, ordinal INTEGER, id TEXT, data TEXT NOT NULL, PRIMARY KEY(analysis,id))'
            );
            $db->do('CREATE INDEX catalog_order ON candidate(analysis,ordinal)');
            my $old = _read( $legacy // "$directory/cache.json" );
            _update( $db, _identified($old), undef, {}, _originals($old) );
            $db->do('PRAGMA user_version = 1');
            return;
        }
    );
    return $db;
}

sub _update ( $db, $updates, $inventory, $sources, $changes ) {
    if ($changes) {
        $db->do( 'INSERT OR REPLACE INTO setting VALUES (?,?)', undef, 'build', $JSON->encode( $changes->{build} ) );
        $db->do('DELETE FROM original') if $changes->{reset};
        for my $test ( keys $changes->{tests}->%* ) {
            my $record = $changes->{tests}{$test};
            if ($record) {
                $db->do( 'INSERT OR REPLACE INTO original VALUES (?,?)', undef, $test, $JSON->encode($record) );
            }
            else { $db->do( 'DELETE FROM original WHERE id = ?', undef, $test ) }
        }
    }
    my $write = _verdict_writer($db);
    $write->( $_, $updates->{$_} ) for keys %$updates;
    if ( defined $inventory ) {
        $db->do( 'DELETE FROM verdict WHERE id NOT IN (SELECT value FROM json_each(?))',
            undef, $JSON->encode($inventory) );
    }
    if (%$sources) {
        $db->do( <<'SQL', undef, $JSON->encode($sources) );
DELETE FROM verdict WHERE rowid IN (
    SELECT saved.rowid FROM json_each(?) current JOIN verdict saved ON saved.path = current.key
    WHERE saved.source <> current.value
)
SQL
    }
    return ( $db->selectrow_array('SELECT count(*) FROM verdict') )[0];
}

sub _verdict_writer ($db) {
    my $put    = $db->prepare('INSERT OR REPLACE INTO verdict VALUES (?,?,?,?)');
    my $remove = $db->prepare('DELETE FROM verdict WHERE id = ?');
    return sub ( $id, $record ) {
        if ( Test::Mutation::Status::of( $record->{status} )->cached ) {
            my ( $path, $source ) = $record->@{qw(path source)};
            $put->execute( $id, $path, $source, $JSON->encode($record) );
        }
        else { $remove->execute($id) }
        return;
    };
}

signature_for checkpoints => ( positional => [Str], returns => CodeRef );

sub checkpoints ($path) {
    unless ( $path =~ /[.]sqlite\z/ ) {
        return sub ( $id, $record, $may_wait = undef ) {
            return 0 if defined $may_wait && !$may_wait;
            save( $path, { $id => $record } );
            return defined $may_wait ? 1 : undef;
        };
    }
    my $db      = database($path);
    my $write   = _verdict_writer($db);
    my $clock   = Test::Mutation::Clock->new;
    my $budget  = $db->sqlite_busy_timeout;
    my $timeout = $budget;
    my $deadline;
    return sub ( $id, $record, $may_wait = undef ) {
        Str->assert_valid($id);
        $RECORD->assert_valid($record);
        my $blocking = $may_wait // 1;
        my $wait     = $blocking ? $budget : 0;
        $wait = List::Util::max( 0, int( ( $deadline - $clock->now ) * 1000 ) ) if $blocking && defined $deadline;
        $db->sqlite_busy_timeout( $timeout = $wait ) if $timeout != $wait;
        my $attempt = Test::Mutation::Try::attempt( sub { $write->( $id, $record ); return 1 } );
        if ( exists $attempt->{error} ) {
            my $code = $db->err;
            $db->set_err( undef, undef );
            if ( !$blocking && defined $code && ( $code & 255 ) == SQLITE_BUSY ) {
                my $now = $clock->now;
                $deadline //= $now + $budget / 1000;
                return 0 if $now < $deadline;
            }
            die $attempt->{error};    ## no critic (ErrorHandling::RequireCarping)
        }
        $deadline = undef;
        return defined $may_wait ? $attempt->{value} : undef;
    };
}

sub _identified ($data) {
    my $verdicts = _validated( $data->{mutants}, $RECORD );
    return { map { $_ => $verdicts->{$_} } grep { defined $verdicts->{$_}{source} } keys %$verdicts };
}

sub _originals ($data) {
    my $build = $data->{build};
    return {
        build => $BUILD->check($build) ? $build : [],
        tests => _validated( $data->{tests}, $ORIGINAL ),
    };
}

sub _validated ( $records, $type ) {
    return {} if ref $records ne 'HASH';
    return { map { $_ => $records->{$_} } grep { $type->check( $records->{$_} ) } keys %$records };
}

sub _read ($path) {
    open my $handle, '<:raw', $path or return {};
    my $text = do { local $/ = undef; readline $handle };
    close $handle or return {};
    my $read   = Test::Mutation::Try::attempt( sub { return [ JSON::PP->new->utf8->decode($text) ] } );
    my ($data) = ( $read->{value} || [] )->@*;
    return ref $data eq 'HASH' && ( $data->{version} || 0 ) eq $FORMAT ? $data : {};
}

signature_for save => (
    positional => [
        Str,
        HashRef [$RECORD],
        Maybe [ ArrayRef [Str] ],
        { default => undef },
        HashRef [Str],
        { default => sub { {} } },
        Maybe [$CHANGES],
        { default => undef }
    ],
    returns => Int
);

sub save ( $path, $updates, $inventory, $sources, $originals ) {
    if ( $path =~ /[.]sqlite\z/ ) {
        my $db = database($path);
        return transaction( $db, sub { _update( $db, $updates, $inventory, $sources, $originals ) } );
    }
    Test::Mutation::Tree::make( File::Basename::dirname($path) );
    open my $lock, '>>', "$path.lock"
      or Test::Mutation::Error::raise( 'file-unwritable', path => "$path.lock", reason => "$!" );
    flock $lock, LOCK_EX or Test::Mutation::Error::raise( 'file-unwritable', path => "$path.lock", reason => "$!" );
    my $count = _merge_records( $path, $updates, $inventory, $sources, $originals );
    close $lock or Test::Mutation::Error::raise( 'file-unclosable', path => "$path.lock", reason => "$!" );
    return $count;
}

sub _merge_records ( $path, $updates, $inventory, $sources, $changes ) {
    my $data      = _read($path);
    my $originals = _originals($data);
    if ($changes) {
        $originals->{build} = $changes->{build};
        $originals->{tests} = {} if $changes->{reset};
        for my $test ( keys $changes->{tests}->%* ) {
            my $record = $changes->{tests}{$test};
            if ($record) { $originals->{tests}{$test} = $record }
            else         { delete $originals->{tests}{$test} }
        }
    }
    my %records  = ( _validated( $data->{mutants}, $RECORD )->%*, %$updates );
    my %eligible = map { $_ => 1 } @{ $inventory || [ keys %records ] };
    my %kept     = map { $_ => $records{$_} } grep {
        my $record = $records{$_};
        $eligible{$_}
          && Test::Mutation::Status::of( $record->{status} )->cached
          && ( !exists $record->{path}
            || !exists $sources->{ $record->{path} }
            || $record->{source} eq $sources->{ $record->{path} } )
    } keys %records;
    my $temporary = "$path.$$";
    open my $handle, '>:raw', $temporary
      or Test::Mutation::Error::raise( 'file-unwritable', path => $temporary, reason => "$!" );
    print {$handle} JSON::PP->new->utf8->canonical->encode( { version => $FORMAT, mutants => \%kept, $originals->%* } )
      or Test::Mutation::Error::raise( 'file-unwritable', path => $temporary, reason => "$!" );
    close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $temporary, reason => "$!" );
    rename $temporary, $path or Test::Mutation::Error::raise( 'file-unrenamable', path => $temporary, reason => "$!" );
    return scalar keys %kept;
}

1;

__END__

=head1 NAME

Test::Mutation::Store - results of earlier runs, keyed by what each result depends on

=head1 SYNOPSIS

    my $records = Test::Mutation::Store::load('.mutation/cache.json');
    my $key     = Test::Mutation::Store::Key::digest( $version, $source_text, @test_digests );
    my $reuse   = $records->{$id} && $records->{$id}{inputs} eq $key;

=head1 DESCRIPTION

A record holds the result of one mutant and, under C<inputs>, the key of its inputs.
No field is named after a key, because a secret scanner reads such a name next to a digest as a credential.
A later run reuses the record when the key of the same mutant is unchanged.

=head1 FUNCTIONS

=head2 read_database

Opens an initialized store for reading and returns C<undef> for a missing file, an empty store, or another file format.

=head2 database

Opens the indexed store and imports reusable records from the previous cache on creation.
An optional second argument names the cache to import from another directory.

=head2 path

Returns the database path for a configured project.
Pass a false second argument for a read on a read-only checkout.
A write uses a temporary snapshot that lasts for the life of the configuration.

=head2 transaction

Runs a database update and commits its return value with the completed work.
If the update returns no value, the transaction returns the database's commit acknowledgement.

=head2 checkpoints

Returns a writer that commits one verdict at a time for the duration of a measurement.
Each call takes a mutant identifier and its observation.
An optional third argument controls whether the writer can wait for another transaction.
With that argument the writer returns true after a commit or false when a busy database needs another attempt.

=head2 format_version

Returns the schema version included in the measurement fingerprint.

=head2 sample

Selects one reusable verdict for every fifty, rounded up, with at least three when available.
The seed changes the selection between runs.

=head2 load

Returns the records of a cache file by mutant identifier.
An optional list of identifiers restricts the lookup to the requested mutants.
A missing file, a file of another format, and a malformed record count as absent.
A record holds a status of L<Test::Mutation::Status>, the reason that its status calls for, and a sentence about the case in C<detail>.

=head2 originals

Returns the build command and the passing observations indexed by test path.
Each observation records the input digest, external include directories, covered targets, breakable lines, and duration.

=head2 save

Writes the records whose status the catalog marks as C<cached>, and returns their number.
Passing original tests and verdicts share one locked update.
An undefined test observation removes an earlier passing result.
A timeout depends on the load of the machine, so the next run measures it again.

=cut
