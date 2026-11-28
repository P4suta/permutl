use v5.36;
use Test2::V0;
use Cwd              ();
use Digest::SHA      ();
use Encode           ();
use Fcntl            qw(LOCK_EX LOCK_NB O_RDONLY);
use File::Copy       ();
use File::Temp       ();
use IO::Socket::UNIX ();
use Socket           ();
use lib 't/lib';
use Capability;
use lib 't/e2e/lib';
use Fixture qw(write_file);
use Test::Mutation::Store::Key;

my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );

sub tree ( $inside = $root ) {
    return Test::Mutation::Store::Key::tree( $inside, [], 1 );
}

subtest 'publication operations validate the names and digests they accept' => sub {
    require Test::Mutation::Report::Publication;
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    isa_ok dies { Test::Mutation::Report::Publication::names('mutation.json') }, ['Error::TypeTiny'],
      'the name list takes no arguments';
    isa_ok dies { Test::Mutation::Report::Publication::outputs( $directory, [] ) }, ['Error::TypeTiny'],
      'the relative directory must be a string';
    isa_ok dies { Test::Mutation::Store::Key::published_outputs( $directory, [], [ [] ] ) }, ['Error::TypeTiny'],
      'every linked input needs a path string';
    isa_ok
      dies { Test::Mutation::Report::Publication::record( $directory, $directory, { 'mutation.json' => 'short' } ) },
      ['Error::TypeTiny'], 'a published checksum must contain a complete SHA-256 digest';
};

subtest 'project data can describe a mutation framework' => sub {
    for my $format (qw(json html)) {
        my $path    = "$root/data/mutation.$format";
        my $content = '{"framework":{"name":"Test::Mutation"},"operand":0}';
        $content = "<html><script>$content</script></html>" if $format eq 'html';
        write_file( $path, $content );
        my $before = tree();
        write_file( $path, $content =~ s/operand":0/operand":1/r );
        isnt tree(), $before, "changed $format input changes the measurement";
    }
};

subtest 'a concurrent publication presents one version of the record and report' => sub {
    my $directory = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $path      = "$directory/mutation.json";
    my $publish   = sub ($bytes) {
        write_file( $path, $bytes );
        Test::Mutation::Report::Publication::record( $directory, $directory,
            { 'mutation.json' => Digest::SHA::sha256_hex($bytes) } );
        return;
    };
    require Test::Mutation::Report::Publication;
    $publish->('first');
    my $before = tree($directory);
    my $file   = \&Test::Mutation::Store::Key::file;
    my ( $during, $attempted, $updated );
    {
        no warnings 'redefine';
        local *Test::Mutation::Store::Key::file = sub ($observed) {
            if ( $observed eq $path && !$attempted++ ) {
                sysopen my $writer, $directory, O_RDONLY or die "open report directory: $!";
                if ( flock $writer, LOCK_EX | LOCK_NB ) {
                    $publish->('replacement');
                    $updated = 1;
                }
                close $writer or die "close report directory: $!";
            }
            return $file->($observed);
        };
        $during = tree($directory);
    }
    $publish->('replacement') unless $updated;
    ok $attempted, 'the publisher attempts to replace the report while the reader checks its bytes';
    is [ $during, tree($directory) ], [ ($before) x 2 ], 'both observations contain only generated files';
    write_file( $path, 'user change' );
    isnt tree($directory), $before, 'a user edit after publication is still measured';
    opendir my $dir, $directory or die "open directory: $!";
    is [ sort grep { $_ ne q{.} && $_ ne q{..} } readdir $dir ], [qw(.test-mutation-outputs mutation.json)],
      'a reader leaves no lock or other file in the project';
    closedir $dir or die "close directory: $!";
};

subtest 'an explicitly excluded report needs no content read' => sub {
    my $directory = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $path      = write_file( "$directory/mutation.json", 'ignored input' );
    my $file      = \&Test::Mutation::Store::Key::file;
    no warnings 'redefine';
    local *Test::Mutation::Store::Key::file = sub ($candidate) {
        die "read excluded input" if $candidate eq $path;
        return $file->($candidate);
    };
    ok lives { Test::Mutation::Store::Key::project( $directory, ['mutation.json'], [] ) },
      'an excluded name is never opened for hashing';
};

subtest 'only published bytes at their recorded paths leave the project input' => sub {
    require Test::Mutation::Report::Publication;
    my $output  = "$root/reports/parts";
    my $before  = tree();
    my %payload = (
        'mutation.json' => '{"framework":{"name":"Test::Mutation"},"score":1}',
        'mutation.html' => '<html><body>score 1</body></html>',
    );
    my %digests = map { $_ => Digest::SHA::sha256_hex( $payload{$_} ) } keys %payload;
    write_file( "$output/$_", $payload{$_} ) for keys %payload;
    Test::Mutation::Report::Publication::record( $root, $output, \%digests );
    is tree(), $before, 'nested directories with only published artifacts leave the inputs alone';
    write_file( "$output/z-data", 'first' );
    isnt tree(), $before, 'a sibling after the published artifacts remains an input';
    my $mixed = tree();
    write_file( "$output/z-data", 'other' );
    isnt tree(), $mixed, 'an edit to the ordinary sibling counts';

    for my $name ( sort keys %payload ) {
        my $with_sibling = tree();
        write_file( "$output/$name", $payload{$name} =~ tr/1/2/r );
        isnt tree(), $with_sibling, "a same-size edit to $name becomes part of the measurement";
        write_file( "$output/$name", $payload{$name} );
    }
    my $published = tree();
    chmod 0755, "$output/mutation.json" or die "make report executable: $!";
    isnt tree(), $published, 'a report repurposed as an executable affects the measurement';
    chmod 0644, "$output/mutation.json"          or die "restore report mode: $!";
    chmod 0755, "$output/.test-mutation-outputs" or die "make metadata executable: $!";
    isnt tree(), $published, 'an executable metadata file is a project input';
    chmod 0644, "$output/.test-mutation-outputs" or die "restore metadata mode: $!";
    my $original = tree();
    write_file( "$root/original.json", $payload{'mutation.json'} );
    my $regular = tree();
    unlink "$output/mutation.json" or die "replace report: $!";
    symlink "$root/original.json", "$output/mutation.json" or die "link report: $!";
    isnt tree(), $regular, 'a symlink to the expected bytes is a project input';
    unlink "$output/mutation.json" or die "remove link: $!";
    write_file( "$output/mutation.json", $payload{'mutation.json'} );
    unlink "$root/original.json" or die "remove original: $!";
    is tree(), $original, 'restoring the published file restores the measurement inputs';
    my $archive         = "$root/archive";
    my $without_archive = tree();
    write_file( "$archive/$_", $payload{$_} ) for keys %payload;
    File::Copy::copy( "$output/.test-mutation-outputs", "$archive/.test-mutation-outputs" ) or die "copy receipt: $!";
    my $copied = tree();
    isnt $copied, $without_archive, 'an exact copy of a publication is ordinary data at another path';
    write_file( "$archive/mutation.json", $payload{'mutation.json'} =~ tr/1/2/r );
    isnt tree(), $copied, 'copying a whole report directory does not exempt its contents at another path';
};

subtest 'a report in a Unicode directory has the same record for characters and path bytes' => sub {
    my $name      = "\x{5831}\x{544a}";
    my $bytes     = Encode::encode( 'UTF-8', $name );
    my $directory = "$root/$bytes";
    my $json      = 'published report';
    write_file( "$directory/mutation.json", $json );
    my $digest = Digest::SHA::sha256_hex($json);
    Test::Mutation::Report::Publication::record( $root, $directory, { 'mutation.json' => $digest } );
    for my $relative ( $name, $bytes ) {
        is Test::Mutation::Report::Publication::outputs( $directory, $relative )->{'mutation.json'}, $digest,
          'the published report matches its relative name';
    }
};

subtest 'publishing preserves a user file with the metadata name and leaves external directories alone' => sub {
    require Test::Mutation::Report::Publication;
    my $directory = "$root/conflict";
    write_file( "$directory/.test-mutation-outputs", 'project data' );
    my $payload = { 'mutation.json' => 'c' x 64 };
    my $before  = tree();
    Test::Mutation::Report::Publication::record( $root, $directory, $payload );
    is tree(), $before, 'an existing unrelated file stays unchanged';
    for my $name (qw(link directory)) {
        my $marker = "$root/$name/.test-mutation-outputs";
        write_file( "$root/$name/target", 'input' );
        if ( $name eq 'link' ) {
            symlink 'target', $marker or die "link: $!";
        }
        else {
            mkdir $marker or die "directory: $!";
        }
        my $original = tree();
        Test::Mutation::Report::Publication::record( $root, "$root/$name", $payload );
        is tree(), $original, "a $name at the metadata path survives publication";
    }
    my $outside = File::Temp::tempdir( CLEANUP => 1 );
    Test::Mutation::Report::Publication::record( $root, $outside, $payload );
    ok !-e "$outside/.test-mutation-outputs", 'publishing outside the measured tree needs no metadata';
};

subtest 'a publication reports an error when its destination is a file' => sub {
    my $destination = write_file( "$root/plain-file", 'ordinary input' );
    my $failure     = dies {
        Test::Mutation::Report::Publication::record( $root, $destination, { 'mutation.json' => 'c' x 64 } );
    };
    is $failure, object { call id => 'file-unwritable' }, 'the caller learns why recording the report failed';
};

subtest 'only a regular publication record in its own directory identifies generated files' => sub {
    my $name      = 'linked-record';
    my $directory = "$root/$name";
    write_file( "$directory/mutation.json", 'saved report' );
    my $digest = Digest::SHA::sha256_hex('saved report');
    Test::Mutation::Report::Publication::record( $root, $directory, { 'mutation.json' => $digest } );
    my $marker = "$directory/.test-mutation-outputs";
    rename $marker, "$directory/previous" or die "move the record: $!";
    symlink 'previous', $marker or die "link the record: $!";
    is Test::Mutation::Report::Publication::outputs( $directory, $name ), {},
      'a symbolic link to an earlier record leaves the files in the measurement';
    my $replacement = { 'mutation.json' => 'b' x 64 };
    is warnings { Test::Mutation::Report::Publication::record( $root, $directory, $replacement ) }, [],
      'skipping a linked record reports no filehandle warnings';
    unlink $marker or die "remove the link: $!";
    rename "$directory/previous", $marker or die "restore the record: $!";
    is Test::Mutation::Report::Publication::outputs( $directory, $name )->{'mutation.json'}, $digest,
      'the earlier publication still records its original bytes';
};

subtest 'malformed publication records leave the directory in the measurement' => sub {
    my $name      = 'invalid-record';
    my $directory = "$root/$name";
    my $seal      = Digest::SHA::sha256_hex( join "\0", $name, 'invalid', '-' );
    for my $text ( 'x' x 512, join( "\n", $seal, 'invalid', '-', q{} ) ) {
        write_file( "$directory/.test-mutation-outputs", $text );
        is Test::Mutation::Report::Publication::outputs( $directory, $name ), {},
          'an oversized record or invalid checksum identifies no generated file';
    }
};

subtest 'a file moved onto the metadata path during publication survives' => sub {
    my $payload = { 'mutation.json' => 'a' x 64 };
    for my $existing ( 0, 1 ) {
        my $directory = "$root/race-$existing";
        my $marker    = "$directory/.test-mutation-outputs";
        my $other     = write_file( "$directory/operand", 'a concurrent input' );
        Test::Mutation::Report::Publication::record( $root, $directory, $payload ) if $existing;
        my $hash  = \&Digest::SHA::sha256_hex;
        my $moved = 0;
        {
            no warnings 'redefine';
            local *Digest::SHA::sha256_hex = sub (@bytes) {
                if ( !$moved++ ) {
                    rename $other, $marker or die "publish concurrent input: $!";
                }
                return $hash->(@bytes);
            };
            Test::Mutation::Report::Publication::record( $root, $directory, $payload );
        }
        ok $moved, 'the input moved onto the path while recording the publication';
        is Test::Mutation::Store::Key::file($marker), Digest::SHA::sha256_hex('a concurrent input'),
          "the concurrent input wins when an earlier record exists: $existing";
    }
};

subtest 'publishing one format retains the other format and preserves hard-linked metadata' => sub {
    my $before    = tree();
    my $directory = "$root/formats";
    for my $format (qw(json html json)) {
        my $name = "mutation.$format";
        my $text = -f "$directory/$name" ? 'revised' : 'original';
        write_file( "$directory/$name", $text );
        Test::Mutation::Report::Publication::record( $root, $directory, { $name => Digest::SHA::sha256_hex($text) } );
        is tree(), $before, "publishing $text $name preserves measurements";
    }
    my $marker = "$directory/.test-mutation-outputs";
    my $data   = "$directory/input";
    link $marker, $data or die "link metadata: $!";
    my $original = Test::Mutation::Store::Key::file($data);
    Test::Mutation::Report::Publication::record( $root, $directory, { 'mutation.json' => 'b' x 64 } );
    is Test::Mutation::Store::Key::file($data), $original, 'a second hard link retains its original bytes';
    is Test::Mutation::Report::Publication::outputs( $directory, 'formats' ), {},
      'a hard-linked metadata file cannot certify output paths';
};

subtest 'a project copy keeps a relative link target and reports dangling links without warnings' => sub {
    my $project   = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $directory = "$project/history";
    my %files     = ( 'mutation.json' => 'json data', 'mutation.html' => 'html data' );
    write_file( "$directory/$_", $files{$_} ) for keys %files;
    my %keys = map { $_ => Digest::SHA::sha256_hex( $files{$_} ) } keys %files;
    Test::Mutation::Report::Publication::record( $project, $directory, \%keys );
    symlink 'history/mutation.json', "$project/input"    or die "link report: $!";
    symlink 'missing',               "$project/dangling" or die "link missing input: $!";
    my $view;
    is warnings { $view = Test::Mutation::Store::Key::project( $project, [], [] ) }, [],
      'the layout can include a dangling project link';
    my %omitted = map { $_ => 1 } $view->{outputs}->@*;
    ok !$omitted{history} && !$omitted{'history/mutation.json'}, 'the link has its original directory and file';
    ok $omitted{'history/mutation.html'}, 'a sibling publication that the link cannot reach stays hidden';
    is $view->{digest}, Test::Mutation::Store::Key::tree( $project, $view->{outputs} ),
      'the project fingerprint includes all bytes that an isolated copy exposes through a link';
    is Test::Mutation::Store::Key::published_outputs( $project, [], [] ), $view->{outputs},
      'an isolated copy keeps every published path reached through an ordinary link';
    is Test::Mutation::Store::Key::published_outputs( $project, [], ['history'] ), [],
      'an explicitly linked directory exposes its original publications';
    is Test::Mutation::Store::Key::project( $project, [], ['history'] )->{outputs}, [],
      'a directory explicitly linked to the real project exposes all its contents';
};

subtest 'finding published paths reads only files that could still match a publication' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $history = "$project/history";
    my $data    = 'archived result';
    write_file( "$history/$_", $data ) for qw(mutation.html mutation.json);
    Test::Mutation::Report::Publication::record( $project, $history,
        { map { $_ => Digest::SHA::sha256_hex($data) } qw(mutation.html mutation.json) } );
    chmod 0755, "$history/mutation.html" or die "set executable mode: $!";
    write_file( "$project/spec/mutation.json", 'project data' );
    write_file( "$project/share/operand",      'ordinary input' );
    symlink 'history/mutation.html', "$project/command" or die "link the executable: $!";
    my @reads;
    my $file = \&Test::Mutation::Store::Key::file;
    no warnings 'redefine';
    local *Test::Mutation::Store::Key::file = sub ($path) {
        push @reads, $path;
        return $file->($path);
    };
    my @published = qw(history/.test-mutation-outputs history/mutation.json);
    is Test::Mutation::Store::Key::published_outputs( $project, [], [] ), \@published,
      'the executable and both ordinary input directories stay in the copy';
    is [ sort @reads ], [ map { "$project/$_" } @published ],
      'only verifiable publication records and report bytes were read';
    symlink 'history/mutation.json', "$project/operand" or die "link the report: $!";
    @reads = ();
    is Test::Mutation::Store::Key::published_outputs( $project, [], [] ), [ $published[0] ],
      'a linked report stays visible as a project input';
    is [ sort @reads ], [ map { "$project/$_" } @published ],
      'keeping a linked report does not require reading unrelated input bytes';
};

subtest 'unreadable entries cannot hide a verified report in another directory' => sub {
    Capability::has( 'unprivileged', $> != 0, 'the fixture needs restricted directory permissions' ) or return;
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $history = "$project/history";
    my $digest  = Digest::SHA::sha256_hex('report bytes');
    write_file( "$history/$_", 'report bytes' ) for qw(mutation.html mutation.json);
    Test::Mutation::Report::Publication::record( $project, $history,
        { 'mutation.html' => $digest, 'mutation.json' => $digest } );
    write_file( "$project/$_/mutation.json", 'private' ) for qw(unlisted unsearchable);
    chmod 0111, "$project/unlisted"      or die "restrict listing: $!";
    chmod 0444, "$project/unsearchable"  or die "restrict search: $!";
    chmod 0000, "$history/mutation.html" or die "restrict report: $!";
    my $outputs = \&Test::Mutation::Report::Publication::outputs;
    my ( @inspected, $found );
    {
        no warnings 'redefine';
        local *Test::Mutation::Report::Publication::outputs = sub ( $directory, $relative ) {
            push @inspected, $relative;
            return $outputs->( $directory, $relative );
        };
        is dies { $found = Test::Mutation::Store::Key::published_outputs( $project, [], [] ) }, undef,
          'the isolated copy can identify outputs with an unreadable file and inaccessible directories';
    }
    chmod( 0700, "$project/unlisted", "$project/unsearchable" ) == 2 or die "restore directories: $!";
    is \@inspected, ['history'], 'publication records are opened only in searchable directories';
    is $found, [qw(history/.test-mutation-outputs history/mutation.json)],
      'the unreadable report stays in the copy and the verified sibling is omitted';
};

subtest 'a socket at a former report path is never opened as a report' => sub {
    my $directory = File::Temp::tempdir( DIR => '/tmp', CLEANUP => 1 );
    my $path      = write_file( "$directory/mutation.json", 'previous output' );
    Test::Mutation::Report::Publication::record( $directory, $directory,
        { 'mutation.json' => Digest::SHA::sha256_hex('previous output') } );
    unlink $path or die "remove report: $!";
    my $socket = IO::Socket::UNIX->new( Type => Socket::SOCK_STREAM(), Local => $path, Listen => 1 )
      or die "listen: $!";
    chmod 0600, $path or die "change socket mode: $!";
    my $view;
    ok lives { $view = Test::Mutation::Store::Key::project( $directory, [], [] ) },
      'a measurement can start while the socket is in use';
    is $view->{outputs}, ['.test-mutation-outputs'], 'only the publication record is generated';
};

done_testing;
