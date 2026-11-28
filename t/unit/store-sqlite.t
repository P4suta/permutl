use v5.36;
use Test2::V0;
use DBI;
use Cwd        ();
use File::Temp ();
use POSIX      ();
use lib 't/lib';
use Capability;
use ManualClock;
use Test::Mutation::Settings;
use Test::Mutation::Source;
use Test::Mutation::Store;

my $directory = File::Temp::tempdir( CLEANUP => 1 );
my $database  = "$directory/measurement.sqlite";
subtest 'an empty lookup leaves the project tree untouched' => sub {
    my $missing = "$directory/absent/measurement.sqlite";
    is Test::Mutation::Store::load($missing),      {},                           'a new checkout has no saved verdicts';
    is Test::Mutation::Store::originals($missing), { build => [], tests => {} }, 'the baseline lookup is empty';
    ok !-e "$directory/absent", 'looking for reusable records creates no directory';
};
my $record = {
    inputs    => 'input',
    path      => 'lib/Sum.pm',
    source    => 'source',
    status    => 'Survived',
    reason    => undef,
    detail    => undef,
    by        => undef,
    tests_run => 1,
    duration  => 1,
    code      => undef
};
Test::Mutation::Store::save( "$directory/cache.json", { first  => $record } );
Test::Mutation::Store::save( $database,               { second => $record } );
is Test::Mutation::Store::load($database), { first => $record, second => $record },
  'the new store imports compatible JSON verdicts before adding its own';

subtest 'reusable records can be read before an interrupted migration resumes' => sub {
    my $saved = { build => [ 'perl', 'Makefile.PL' ], tests => {} };
    my $old   = "$directory/partial/cache.json";
    Test::Mutation::Store::save( $old, { earlier => $record }, undef, {}, $saved );
    for my $case (
        [ verdicts => \&Test::Mutation::Store::load,      { earlier => $record } ],
        [ baseline => \&Test::Mutation::Store::originals, $saved ]
      )
    {
        my ( $name, $read, $expected ) = @$case;
        my $empty = "$directory/partial/$name.sqlite";
        open my $file, '>:raw', $empty or die "create $empty: $!";
        close $file or die "close $empty: $!";
        is $read->($empty), $expected, "the $name lookup can use the legacy cache";
        is -s $empty,       0,         "reading $name leaves the incomplete SQLite file untouched";
    }
    my %unidentified = %$record;
    delete @unidentified{qw(path source)};
    Test::Mutation::Store::save( $old, { other => $record, unidentified => \%unidentified } );
    is Test::Mutation::Store::load( "$directory/partial/verdicts.sqlite", [qw(missing unidentified earlier)] ),
      { earlier => $record }, 'selection from the JSON fallback requires both a requested identifier and known source';
};

my $db = DBI->connect( "dbi:SQLite:dbname=$database", undef, undef, { RaiseError => 1, PrintError => 0 } );
is $db->selectcol_arrayref('SELECT id FROM verdict ORDER BY id'), [qw(first second)],
  'the driver persists a separately addressable row for each verdict';
subtest 'cache paths preserve filename punctuation' => sub {
    my $literal = "$directory/cache;name=100%24?#/measurement.sqlite";
    Test::Mutation::Store::save( $literal, { punctuated => $record } );
    ok -f $literal, 'the database occupies the complete requested path';
    is Test::Mutation::Store::load($literal), { punctuated => $record }, 'the requested database contains the verdict';
};

subtest 'a cache file in another format keeps its bytes and falls back to legacy records' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    my $path = "$root/measurement.sqlite";
    my $data = "other application\0data\n";
    open my $file, '>:raw', $path or die "create $path: $!";
    print {$file} $data;
    close $file or die "close $path: $!";
    is lives { is Test::Mutation::Store::load($path), {}, 'a missing legacy cache yields no verdict' }, T(),
      'reading an unrecognized file counts as a cache miss';
    my $baseline = { build => ['perl'], tests => {} };
    Test::Mutation::Store::save( "$root/cache.json", { previous => $record }, undef, {}, $baseline );
    is lives {
        is Test::Mutation::Store::load($path), { previous => $record }, 'verified legacy verdicts are available';
        is Test::Mutation::Store::originals($path), $baseline, 'the legacy build is available';
    }, T(), 'legacy fallback works when the SQLite path contains other bytes';
    like dies { Test::Mutation::Store::save( $path, { later => $record } ) }, qr/\Q$path\E.*--no-cache.*--cache-dir/,
      'a writer names ways to finish the measurement while preserving the file';
    is Test::Mutation::Source::read_bytes($path), $data, 'both operations preserve the original bytes';
};

subtest 'an explicit legacy cache can be named zero' => sub {
    my $folder = "$directory/numeric-legacy";
    Test::Mutation::Store::save( "$folder/0",          { requested => $record } );
    Test::Mutation::Store::save( "$folder/cache.json", { neighbor  => $record } );
    my $before = Cwd::getcwd();
    chdir $folder or die "chdir $folder: $!";
    my $error = dies { Test::Mutation::Store::database( "$folder/measurement.sqlite", '0' ) };
    chdir $before or die "restore $before: $!";
    is $error, undef, 'the path is valid even though its spelling is false in Perl';
    is Test::Mutation::Store::load("$folder/measurement.sqlite"), { requested => $record },
      'only the explicitly requested file supplies migrated observations';
};

subtest 'an unsupported SQLite schema remains an actionable error' => sub {
    my $path       = "$directory/future.sqlite";
    my $connection = DBI->connect( "dbi:SQLite:dbname=$path", undef, undef, { RaiseError => 1, PrintError => 0 } );
    $connection->do('PRAGMA user_version = 314');
    like dies { Test::Mutation::Store::load($path) }, qr/unsupported database schema 314/,
      'the reader reports the version of an existing SQLite database';
    like dies { Test::Mutation::Store::save( $path, { later => $record } ) }, qr/unsupported database schema 314/,
      'the writer preserves an unsupported schema';
    is $connection->selectrow_array('PRAGMA user_version'), 314, 'the original schema version survives';
};

subtest 'an unreadable SQLite database reports the access failure' => sub {
    Capability::need( 'unprivileged', $> != 0, 'the superuser can read protected files' );
    my $path = "$directory/protected/measurement.sqlite";
    Test::Mutation::Store::save( $path, { earlier => $record } );
    chmod oct('000'), $path or die "protect $path: $!";
    my $error = dies { Test::Mutation::Store::load($path) };
    chmod oct('600'), $path or die "restore $path: $!";
    like $error, qr/cannot read \Q$path\E/, 'a permission error remains visible at the database path';
    is Test::Mutation::Store::load($path), { earlier => $record }, 'restoring access recovers the original verdict';
};

subtest 'an unreadable cached verdict is measured again without losing its neighbors' => sub {
    my $path = "$directory/damaged/measurement.sqlite";
    Test::Mutation::Store::save( $path, { map { $_ => $record } qw(ambiguous broken missing intact) } );
    my $connection = Test::Mutation::Store::database($path);
    $connection->do(
        q{UPDATE verdict SET data = replace(data,'"status":"Survived"','"status":"Killed","status":"Survived"') WHERE id = 'ambiguous'}
    );
    $connection->do( 'UPDATE verdict SET data = ? WHERE id = ?', undef, '{',    'broken' );
    $connection->do( 'UPDATE verdict SET data = ? WHERE id = ?', undef, 'null', 'missing' );
    is Test::Mutation::Store::load($path), { intact => $record }, 'only the intact verdict can be reused';
};

subtest 'a damaged build setting preserves independently recorded baseline observations' => sub {
    my $path  = "$directory/build/measurement.sqlite";
    my $build = [ 'perl', 'Makefile.PL' ];
    my $tests = { 't/sum.t' => { inputs => 'measured', includes => [], duration => 1, files => {}, breakable => {} } };
    Test::Mutation::Store::save( $path, {}, undef, {}, { build => $build, tests => $tests } );
    is Test::Mutation::Store::originals($path), { build => $build, tests => $tests }, 'valid build arguments survive';
    my $connection = Test::Mutation::Store::database($path);
    for my $case (
        [ 'broken JSON'   => '{' ],
        [ 'object'        => '{}' ],
        [ 'nested object' => '["perl",{}]' ],
        [ 'null argument' => '["perl",null]' ]
      )
    {
        my ( $fault, $value ) = @$case;
        $connection->do( q{UPDATE setting SET data = ? WHERE id = 'build'}, undef, $value );
        my $saved;
        my $error = dies { $saved = Test::Mutation::Store::originals($path) };
        is [ $error, $saved ], [ undef, { build => [], tests => $tests } ], "the baseline survives $fault";
    }
};

subtest 'invalidating one source takes bounded work as unrelated verdicts grow' => sub {
    my $path    = "$directory/pruning/measurement.sqlite";
    my $current = { %$record, source => 'current' };
    my $open    = \&Test::Mutation::Store::database;
    my $prune   = sub ($remaining) {
        Test::Mutation::Store::save( $path, { changed => $record, current => $current } );
        my $hundreds = 0;
        {
            no warnings 'redefine';
            local *Test::Mutation::Store::database = sub ($file) {
                my $connection = $open->($file);
                $connection->sqlite_progress_handler( 100, sub { $hundreds++; return 0 } );
                return $connection;
            };
            is Test::Mutation::Store::save( $path, {}, undef, { $record->{path} => $current->{source} } ), $remaining,
              'only the obsolete verdict is removed';
        }
        is Test::Mutation::Store::load( $path, [qw(changed current)] ), { current => $current },
          'the matching source revision remains reusable';
        return $hundreds;
    };
    my $small = $prune->(1);
    Test::Mutation::Store::save( $path, { map { $_ => { %$record, path => "lib/Other$_.pm" } } 1 .. 1_000 } );
    cmp_ok $prune->(1_001), '<=', $small + 1,
      'one thousand unrelated paths cost at most one extra block of one hundred SQLite operations';
};

subtest 'another writer can finish the schema after the first probe' => sub {
    my $transaction = \&Test::Mutation::Store::transaction;
    my $open        = sub ( $path, $publish ) {
        no warnings 'redefine';
        local *Test::Mutation::Store::transaction = sub ( $db, $operation ) {
            local *Test::Mutation::Store::transaction = $transaction;
            $publish->($path);
            return $transaction->( $db, $operation );
        };
        return Test::Mutation::Store::database( $path, undef );
    };
    my $path       = "$directory/raced/measurement.sqlite";
    my $connection = $open->( $path, sub ($file) { Test::Mutation::Store::save( $file, { peer => $record } ) } );
    is $connection->selectcol_arrayref('SELECT id FROM verdict'), ['peer'],
      'the first writer opens the schema and observations committed by its peer';
    is Test::Mutation::Store::load($path), { peer => $record }, 'the completed observation remains readable';
    like dies {
        $open->(
            "$directory/raced/future.sqlite",
            sub ($file) {
                my $peer = DBI->connect( "dbi:SQLite:dbname=$file", undef, undef, { RaiseError => 1 } );
                $peer->do('PRAGMA user_version = 314');
            }
        );
    }, qr/unsupported database schema 314/, 'a competing writer can install a schema this driver cannot open';
};

subtest 'each request reads the file acquired by its first connection' => sub {
    my $connect = \&DBI::connect;
    for my $case (
        [
            handle => sub ($path) {
                return Test::Mutation::Store::database($path)->selectcol_arrayref('SELECT id FROM verdict');
            }
        ],
        [ verdicts => sub ($path) { return [ keys Test::Mutation::Store::load($path)->%* ] } ]
      )
    {
        my ( $name, $read ) = @$case;
        my $path = "$directory/$name/measurement.sqlite";
        my $next = "$directory/$name/replacement.sqlite";
        Test::Mutation::Store::save( $path, { original    => $record } );
        Test::Mutation::Store::save( $next, { replacement => $record } );
        my $opens = 0;
        my $ids;
        {
            no warnings 'redefine';
            local *DBI::connect = sub (@args) {
                my $handle = $connect->(@args);
                if ( ++$opens == 1 ) { rename $next, $path or die "replace $path: $!" }
                return $handle;
            };
            $ids = $read->($path);
        }
        is $ids,   ['original'], "the $name request keeps its first database";
        is $opens, 1,            "one $name request opens one connection";
        is Test::Mutation::Store::load($path), { replacement => $record }, 'a later request opens the replacement file';
    }
};

subtest 'concurrent writers publish only committed observations' => sub {
    my $path = "$directory/concurrent/measurement.sqlite";
    pipe my $start, my $signal or die "pipe: $!";
    my @children;
    for my $number ( 1 .. 2 ) {
        my $child = fork;
        die "fork: $!" unless defined $child;
        if ( !$child ) {
            close $signal                        or die "close: $!";
            sysread( $start, my $ready, 1 ) == 1 or die "start gate: $!";
            Test::Mutation::Store::save( $path, { $number => $record } );
            POSIX::_exit(0);
        }
        push @children, $child;
    }
    close $start                   or die "close: $!";
    syswrite( $signal, 'xx' ) == 2 or die "release: $!";
    close $signal                  or die "close: $!";
    for my $child (@children) {
        waitpid $child, 0;
        is $?, 0, 'a writer commits successfully';
    }
    my $both = { 1 => $record, 2 => $record };
    is Test::Mutation::Store::load($path), $both, 'both writers survive concurrent database creation';
    my $connection = Test::Mutation::Store::database($path);
    like dies {
        Test::Mutation::Store::transaction(
            $connection,
            sub {
                $connection->do('DELETE FROM verdict');
                die "interrupted publication\n";
            }
        );
    }, qr/interrupted publication/, 'an interrupted transaction returns its original failure';
    is $connection->selectcol_arrayref('SELECT id FROM verdict ORDER BY id'), [qw(1 2)],
      'the writer sees the previously committed observations after its transaction fails';
    is Test::Mutation::Store::load($path), $both, 'a rolled-back write preserves every committed observation';
    is dies {
        Test::Mutation::Store::transaction( $connection,
            sub { $connection->do(q{INSERT INTO setting VALUES ('next','ready')}) } );
    }, undef, 'the same writer can begin a new transaction immediately after rollback';
    is Test::Mutation::Store::read_database($path)->selectrow_array(q{SELECT data FROM setting WHERE id = 'next'}),
      'ready', 'another connection can read the next commit';
};

subtest 'a write-only transaction returns the database acknowledgement' => sub {
    my $path       = "$directory/write-only/measurement.sqlite";
    my $connection = Test::Mutation::Store::database($path);
    isa_ok dies { Test::Mutation::Store::transaction( $connection, 'DELETE FROM verdict' ) }, ['Error::TypeTiny'],
      'a transaction requires a callback before opening the write';
    my $acknowledged;
    is dies {
        $acknowledged = Test::Mutation::Store::transaction(
            $connection,
            sub {
                $connection->do(q{INSERT INTO setting VALUES ('saved','yes')});
                return;
            }
        );
    }, undef, 'a committed write needs no result from the callback';
    ok $acknowledged, 'the caller receives the successful commit result';
    is Test::Mutation::Store::read_database($path)->selectrow_array(q{SELECT data FROM setting WHERE id = 'saved'}),
      'yes', 'another connection can read the committed change';
    is Test::Mutation::Store::transaction( $connection, sub { return 0 } ), 0,
      'a defined false callback result passes through the transaction';
};

subtest 'a rejected commit rolls back before the caller receives a result' => sub {
    my $connection = DBI->connect( 'dbi:SQLite::memory:', undef, undef, { RaiseError => 0, PrintError => 0 } );
    $connection->do('PRAGMA foreign_keys = ON');
    $connection->do('CREATE TABLE parent (id INTEGER PRIMARY KEY)');
    $connection->do('CREATE TABLE child (parent INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)');
    like dies {
        Test::Mutation::Store::transaction(
            $connection,
            sub {
                $connection->do('INSERT INTO child VALUES (42)');
                return 'ready';
            }
        );
    }, qr/FOREIGN KEY constraint failed/, 'the database refuses the commit after the callback returns';
    is $connection->selectrow_array('SELECT count(*) FROM child'), 0, 'the writer has rolled back the invalid row';
    ok !$connection->{RaiseError}, 'the caller keeps its DBI error policy';
};

subtest 'a commit veto keeps the original error after SQLite rolls back' => sub {
    my $connection = DBI->connect( 'dbi:SQLite::memory:', undef, undef, { RaiseError => 1, PrintError => 0 } );
    $connection->do('CREATE TABLE items (id INTEGER)');
    $connection->sqlite_commit_hook( sub { return 1 } );
    like dies {
        Test::Mutation::Store::transaction( $connection, sub { $connection->do('INSERT INTO items VALUES (1)') } );
    }, qr/constraint failed/i, 'the caller receives the rejection from the commit hook';
    is $connection->selectcol_arrayref('SELECT id FROM items'), [], 'the engine has already rolled back the insertion';
};

sub checkpoints_on ( $path, $connection ) {
    no warnings 'redefine';
    local *Test::Mutation::Store::database = sub ($) { return $connection };
    return Test::Mutation::Store::checkpoints($path);
}

subtest 'a nonblocking checkpoint retries only a competing writer' => sub {
    my $path   = "$directory/checkpoints/measurement.sqlite";
    my $writer = Test::Mutation::Store::database($path);
    my $peer   = Test::Mutation::Store::database($path);
    $writer->sqlite_busy_timeout(100);
    my $write = checkpoints_on( $path, $writer );
    $peer->do('BEGIN IMMEDIATE');
    is $write->( 'example', $record, 0 ), 0, 'a competing write lock leaves the observation pending';
    is $peer->selectrow_array('SELECT count(*) FROM verdict'), 0, 'no partial observation is visible';
    my $malformed = { %$record, inputs => chr(0xd800) };
    like dies { $write->( 'malformed', $malformed, 0 ) }, qr/cannot convert to JSON/,
      'a previous lock conflict cannot hide a new encoder failure';
    is $writer->sqlite_busy_timeout, 0, 'SQLite returns control immediately while another writer holds the lock';
    $peer->do('COMMIT');
    is $write->( 'example', $record, 0 ), 1, 'the pending observation commits when the lock clears';
    is Test::Mutation::Store::load($path), { example => $record }, 'another connection sees the commit';
    my $error;
    is warnings {
        $error = dies { $write->( 'malformed', $malformed, 0 ) }
    }, [], 'an encoding failure before any SQLite operation emits no database warning';
    like $error, qr/cannot convert to JSON/, 'a malformed Unicode input returns its original encoder error';
    $peer->do(q{CREATE TRIGGER reject BEFORE INSERT ON verdict BEGIN SELECT RAISE(ABORT,'rejected record'); END});
    like dies { $write->( 'refused', $record, 0 ) }, qr/rejected record/,
      'a rejected write passes its failure to the caller';
};

subtest 'a blocking checkpoint uses the remainder of the original lock timeout' => sub {
    my $path   = "$directory/retry/measurement.sqlite";
    my $writer = Test::Mutation::Store::database($path);
    my $peer   = Test::Mutation::Store::database($path);
    my $clock  = ManualClock->new( at => -2 );
    $writer->sqlite_busy_timeout(2_000);
    my $write = do {
        no warnings 'redefine';
        local *Test::Mutation::Clock::new = sub ($) { return $clock };
        checkpoints_on( $path, $writer );
    };
    $peer->do('BEGIN IMMEDIATE');
    is $write->( 'delayed', $record, 0 ), 0, 'the first lock conflict starts the deadline';
    $clock->move(1);
    is $write->( 'delayed', $record, 0 ), 0, 'a second conflict keeps the original deadline at the clock origin';
    $clock->move(0.2495);
    $peer->do('COMMIT');
    is $write->( 'delayed', $record, 1 ), 1,     'the blocking retry commits the pending verdict';
    is $writer->sqlite_busy_timeout,      750,   'SQLite can wait the remaining whole milliseconds';
    is $write->( 'next', $record, 1 ),    1,     'the next checkpoint commits independently';
    is $writer->sqlite_busy_timeout,      2_000, 'a new checkpoint receives the full lock timeout';
    is Test::Mutation::Store::load($path), { delayed => $record, next => $record }, 'both commits are durable';
};

subtest 'SQLite acknowledges a removal even when the verdict is already absent' => sub {
    my $path    = "$directory/removal/measurement.sqlite";
    my $write   = Test::Mutation::Store::checkpoints($path);
    my $pending = { %$record, status => 'Pending', reason => 'interrupted' };
    is $write->( 'example', $record ), undef, 'a caller without a wait argument receives no acknowledgement';
    is Test::Mutation::Store::load($path), { example => $record }, 'the completed observation was committed';
    is $write->( 'example', $pending, 1 ), 1, 'the writer acknowledges removal of the superseded verdict';
    is $write->( 'example', $pending, 1 ), 1, 'a retry can acknowledge the same removal';
    is Test::Mutation::Store::load($path), {}, 'an interrupted observation leaves no reusable verdict';
};

subtest 'a malformed checkpoint cannot replace a reusable verdict' => sub {
    my $path  = "$directory/invalid/measurement.sqlite";
    my $write = Test::Mutation::Store::checkpoints($path);
    $write->( 'saved', $record, 1 );
    like dies { $write->( [], $record, 1 ) }, qr/type constraint/,
      'a reference cannot become the identifier of another saved verdict';
    like dies { $write->( 'saved', { %$record, duration => [] }, 1 ) }, qr/type constraint/,
      'a completed observation requires a numeric duration';
    is Test::Mutation::Store::load($path), { saved => $record }, 'both refusals preserve the original verdict';
};

subtest 'legacy checkpoints defer file locking until the caller can wait' => sub {
    my $path  = "$directory/legacy-checkpoint/cache.json";
    my $write = Test::Mutation::Store::checkpoints($path);
    is $write->( 'first', $record, 0 ), 0, 'the nonblocking attempt leaves the observation pending';
    ok !-e "$path.lock", 'a deferred checkpoint creates no lock file';
    is $write->( 'first', $record, 1 ), 1, 'a blocking retry acknowledges the saved observation';
    is $write->( 'second', $record ), undef, 'a caller without a wait argument retains its return contract';
    is Test::Mutation::Store::load($path), { first => $record, second => $record }, 'both observations are durable';
};

subtest 'measurements in a read-only checkout' => sub {
    Capability::need( 'unprivileged', $> != 0, 'the superuser can write to read-only directories' );
    my $read_only = File::Temp::tempdir( CLEANUP => 1 );
    my $config    = Test::Mutation::Settings::of_call( { root => $read_only } );
    my $legacy    = "$read_only/.mutation/cache.json";
    Test::Mutation::Store::save( $legacy, { first => $record } );
    chmod oct('555'), $read_only or die "chmod: $!";
    my $private = Test::Mutation::Store::path($config);
    is Test::Mutation::Store::load($private), { first => $record },
      'input-identified verdicts migrate from a read-only checkout into the private database';
    ok !-e "$read_only/.mutation/measurement.sqlite", 'migration leaves the checkout intact';
    chmod oct('755'), $read_only or die "chmod: $!";
    ok index( $private, "$read_only/" ) != 0, 'a read-only project uses a private database outside the checkout';
    is Test::Mutation::Store::path($config), $private, 'the configuration keeps its private database for the whole run';
};

subtest 'a read-only checkout can recover an unfinished legacy migration' => sub {
    Capability::need( 'unprivileged', $> != 0, 'the superuser can write to read-only directories' );
    my $root   = File::Temp::tempdir( CLEANUP => 1 );
    my $config = Test::Mutation::Settings::of_call( { root => $root } );
    Test::Mutation::Store::save( "$root/.mutation/cache.json", { previous => $record } );
    my $sqlite = Test::Mutation::Store::path( $config, 0 );
    open my $empty, '>:raw', $sqlite or die "create $sqlite: $!";
    close $empty or die "close $sqlite: $!";
    chmod oct('555'), $root or die "protect $root: $!";
    my $copy = Test::Mutation::Store::path($config);
    is Test::Mutation::Store::load($copy), { previous => $record },
      'the private measurement retains the legacy verdict';
    is -s $sqlite, 0, 'the unfinished database in the checkout still contains no schema';
    chmod oct('755'), $root or die "restore $root: $!";
};
done_testing;
