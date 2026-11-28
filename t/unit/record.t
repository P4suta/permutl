use v5.36;
use Test2::V0;
use File::Temp ();
use Test::Mutation::Record;

sub lines (@rows) {
    return join q{}, map { join( "\t", $_->@* ) . "\n" } @rows;
}

subtest 'indexed witnesses report an unknown target and continue decoding' => sub {
    my $record = Test::Mutation::Record::parse(
        [ lines( [ 'begin', 0 ], [ 'blind', 8 ], [ 'blind', 1 ], [ 'blind', '/p/Named.pm' ], [ 'end', 23 ] ) ],
        [qw(/p/A.pm /p/B.pm)] );
    is $record->{errors}, ['unknown target index 8'], 'an unregistered index supplies a diagnostic';
    is $record->{compiled}, { '/p/B.pm' => 1, '/p/Named.pm' => 1 }, 'both kinds of subsequent witnesses remain valid';
    is $record->{ended},                                            1, 'the process ending is still observed';
};

subtest 'a traced process' => sub {
    my $record = Test::Mutation::Record::parse(
        [
            lines(
                [ 'begin', 1 ],
                [ 'seen',  '/p/lib/A.pm', 'opened' ],
                [ 'hit',   '/p/lib/A.pm', 3 ],
                [ 'hit',   '/p/lib/A.pm', 7 ],
                [ 'lines', '/p/lib/A.pm', '3,5,7' ],
                [ 'end',   4242 ],
            )
        ]
    );
    is $record->{served}, { '/p/lib/A.pm' => { traced => 1, hits => { 3 => 1, 7 => 1 } } }, 'served file with its hits';
    is $record->{breakable},   { '/p/lib/A.pm' => { 3 => 1, 5 => 1, 7 => 1 } },             'breakable lines';
    is $record->{load_failed}, {},                                                          'no load failure';
    is $record->{bypassed},    {},                                                          'no bypass';
};

subtest 'load failures, bypasses, and errors' => sub {
    my $record = Test::Mutation::Record::parse(
        [
            lines(
                [ 'begin',  0 ],
                [ 'seen',   '/p/A.pm', 'opened' ],
                [ 'seen',   '/p/A.pm', 'failed' ],
                [ 'around', '/p/B.pm' ],
                [ 'error',  '/p/C.pm', 'cannot open' ],
                [ 'error',  '/p/D.pm', 'cannot read' ],
            )
        ]
    );
    is $record->{load_failed}, { '/p/A.pm' => 1 }, 'load failure';
    is $record->{bypassed},    { '/p/B.pm' => 1 }, 'bypass';
    is $record->{errors}, [ '/p/C.pm: cannot open', '/p/D.pm: cannot read' ], 'errors in the order of the record';
    is $record->{served}{'/p/A.pm'}{traced}, 0, 'an untraced process marks the file as untraced';
};

subtest 'several processes of one test run' => sub {
    my $traced   = lines( [ 'begin', 1 ], [ 'seen', '/p/A.pm', 'opened' ], [ 'hit', '/p/A.pm', 2 ] );
    my $untraced = lines( [ 'begin', 0 ], [ 'seen', '/p/A.pm', 'opened' ] );
    my $other    = lines( [ 'begin', 1 ], [ 'seen', '/p/B.pm', 'opened' ], [ 'hit', '/p/B.pm', 9 ] );
    is Test::Mutation::Record::parse( [ $traced, $other ] )->{served},
      { '/p/A.pm' => { traced => 1, hits => { 2 => 1 } }, '/p/B.pm' => { traced => 1, hits => { 9 => 1 } } },
      'files of different processes are merged';
    is Test::Mutation::Record::parse( [ $traced, $untraced ] )->{served}{'/p/A.pm'},
      { traced => 0, hits => { 2 => 1 } },
      'one untraced process makes the file untraced';
    is Test::Mutation::Record::parse( [ $untraced, $traced ] )->{served}{'/p/A.pm'}{traced}, 0, 'whatever the order';
};

subtest 'a module listed at exit uses the compilation observed by the same process' => sub {
    my $target = '/p/A.pm';
    my $other  = '/p/B.pm';
    my $traced = lines( [ 'begin', 1 ], [ 'seen', $target ], [ 'hit', $target, 4 ] );
    my $listed = lines( [ 'blind', $target, 'loaded-at-exit' ] );
    my $observed =
      Test::Mutation::Record::parse( [ $traced . $listed . lines( [ 'blind', $other, 'loaded-at-exit' ] ) ] );
    is $observed->{errors}, [], 'finding a module on disk at exit is a valid observation';
    is $observed->{served},
      { $target => { traced => 1, hits => { 4 => 1 } }, $other => { traced => 0, hits => {} } },
      'a successful trace explains only the file that supplied it';
    is $observed->{compiled}, { $target => 1, $other => 1 }, 'the module registry confirms both loads';
    my $restart = lines( [ 'begin', 1 ] );
    is Test::Mutation::Record::parse( [ $traced, $restart . $listed ] )->{served}{$target}{traced}, 0,
      'a different process can have loaded the same module without tracing';
    is Test::Mutation::Record::parse( [ $traced . $restart . $listed ] )->{served}{$target}{traced}, 0,
      'an unfinished interpreter cannot borrow a trace from before exec';
    my $after_exec = lines( [ 'begin', 1 ], [ 'seen', $other ], [ 'hit', $other, 9 ] );
    my $shutdown   = lines( [ 'blind', $other, 'loaded-at-exit' ], [ 'end', 23 ], [ 'end', 23 ] );
    is Test::Mutation::Record::parse( [ $traced . $after_exec . $restart . $listed . $shutdown ] )->{served},
      { $target => { traced => 0, hits => { 4 => 1 } }, $other => { traced => 1, hits => { 9 => 1 } } },
      'only the two observers that reach shutdown can share their compilation after exec';
    is Test::Mutation::Record::parse( [ $listed . $traced ] )->{served}{$target}{traced}, 0,
      'a later compilation cannot explain an earlier observation';
    my $opened = lines( [ 'begin', 1 ], [ 'seen', $target, 'opened' ] );
    is Test::Mutation::Record::parse( [ $opened . $listed ] )->{served}{$target}{traced}, 0,
      'opening a source alone never proves its compilation was traced';
    my $blind = lines( [ 'blind', $target ] );

    for my $history ( $traced . $blind, $traced . $blind . $listed, $traced . $listed . $blind ) {
        is Test::Mutation::Record::parse( [$history] )->{served}{$target},
          { traced => 0, hits => { 4 => 1 } },
          'an explicit blind load keeps file coverage alongside actual hits and a load listed at exit';
    }
};

subtest 'unknown and malformed records leave a diagnostic' => sub {
    my $record = Test::Mutation::Record::parse( ["begin\t1\nmystery\t/p/A.pm\nseen\n\nhit\t/p/A.pm\n"] );
    is $record->{errors},
      [ 'unknown record kind mystery', 'missing field for record kind seen', '/p/A.pm: invalid hit line' ],
      'unknown kinds, missing paths, and missing line numbers each retain their diagnostic';
    my $zero = Test::Mutation::Record::parse( ["begin\t1\nseen\t/p/A.pm\t0\n"] );
    is [ $zero->{errors}, $zero->{compiled} ], [ ['/p/A.pm: unknown load stage 0'], {} ],
      'a zero field is an unknown stage and cannot confirm a compilation';
    is $record->{served},                             {}, 'malformed records do not establish coverage';
    is Test::Mutation::Record::parse( [] )->{served}, {}, 'no record files';

    my $after =
      Test::Mutation::Record::parse( ["begin\t1\nseen\naround\t/p/A.pm\nmystery\t/p/B.pm\nseen\t/p/C.pm\tfailed\n"] );
    is [ $after->{bypassed}, $after->{load_failed} ], [ { '/p/A.pm' => 1 }, { '/p/C.pm' => 1 } ],
      'the lines after a malformed line and after an unknown kind still count';
    my $stages = Test::Mutation::Record::parse(
        ["begin\t1\nerror\t/p/B.pm\tfirst\nseen\t/p/A.pm\twaiting\nmisspelt\tpath\nseen\t\topened\n"] );
    is $stages->{errors},
      [
        '/p/B.pm: first',
        '/p/A.pm: unknown load stage waiting',
        'unknown record kind misspelt',
        'missing field for record kind seen'
      ],
      'errors retain wire order and an empty path supplies no target';
    like dies { Test::Mutation::Record::parse( [ {} ] ) }, qr/Str/, 'each process stream must be a string';
    like dies { Test::Mutation::Record::read_directory( File::Temp->newdir ) }, qr/Str/,
      'a directory must be a path string';
};

subtest 'a compiled line marks a target that compiled' => sub {
    my $record = Test::Mutation::Record::parse(
        [
            lines(
                [ 'begin', 0 ],
                [ 'seen',  '/p/A.pm', 'opened' ],
                [ 'seen',  '/p/A.pm' ],
                [ 'seen',  '/p/B.pm', 'opened' ]
            )
        ]
    );
    is $record->{compiled}, { '/p/A.pm' => 1 }, 'the compiled target, without the one that failed';
};

subtest 'read_directory reads every record file' => sub {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    for my $file (
        [ 'one.rec',  lines( [ 'begin', 1 ], [ 'seen',   '/p/A.pm', 'opened' ], [ 'error', '/p/A.pm', 'first' ] ) ],
        [ 'two.rec',  lines( [ 'begin', 1 ], [ 'around', '/p/B.pm' ], [ 'error', '/p/B.pm', 'second' ] ) ],
        [ 'note.txt', 'served' ]
      )
    {
        open my $handle, '>', "$directory/$file->[0]" or die "open: $!";
        print {$handle} $file->[1] or die "print: $!";
        close $handle              or die "close: $!";
    }
    my $record = Test::Mutation::Record::read_directory($directory);
    is [ sort keys $record->{served}->%* ],   ['/p/A.pm'],         'served';
    is [ sort keys $record->{bypassed}->%* ], ['/p/B.pm'],         'bypassed';
    is $record->{errors}, [ '/p/A.pm: first', '/p/B.pm: second' ], 'the errors follow the names of the files';
};

subtest 'library directories from child processes keep their filename bytes' => sub {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    my @paths     = ( '/a dir', "/lib\tone", "/raw/\xff" );
    my @hex       = map { unpack 'H*', $_ } @paths;
    for my $file ( [ 'one.inc', [ @hex[ 2, 0 ], 'bad', 'not-hex' ] ], [ 'two.inc', [ @hex[ 1, 0 ] ] ],
        [ 'empty.inc', [] ] )
    {
        open my $handle, '>:raw', "$directory/$file->[0]" or die "open: $!";
        print {$handle} "$_\n" for $file->[1]->@*;
        close $handle or die "close: $!";
    }
    my $record = Test::Mutation::Record::read_directory($directory);
    is $record->{includes}, \@paths, 'complete hexadecimal paths are decoded, deduplicated, and sorted';
};

subtest 'records account for process boundaries and reject unknown kinds' => sub {
    my $record = Test::Mutation::Record::parse( [ "begin\t1\nseen\t/p/A.pm\nend\t24\n", "begin\t0\n" ] );
    is [ $record->{begun}, $record->{ended} ], [ 2, 1 ], 'a process can end before the END block';
    is $record->{compiled}, { '/p/A.pm' => 1 }, 'a witness identifies the target that compiled';
    is Test::Mutation::Record::parse( ["begin\t0\nmisspelt\t/p/A.pm\n"] )->{errors},
      ['unknown record kind misspelt'], 'a stream with an unknown kind cannot support a verdict';
};

like dies { Test::Mutation::Record::read_directory( [] ) }, qr/Str/, 'the record directory must be a path string';

subtest 'the record directory is a literal path' => sub {
    my $base = File::Temp::tempdir( CLEANUP => 1 );
    my $path = "$base/records [a]*?";
    mkdir $path or die "mkdir: $!";
    open my $handle, '>:raw', "$path/child.rec" or die "open: $!";
    print {$handle} "begin\t1\noutside\t/p/A.pm\nend\t24\n" or die "write: $!";
    close $handle                                           or die "close: $!";
    is Test::Mutation::Record::read_directory($path)->{outside}, { '/p/A.pm' => 1 },
      'the outside load is read from the directory with spaces and pattern characters';
};

subtest 'evidence separates a missing observer from an untested target' => sub {
    require Test::Mutation::Evidence;
    my $evidence = sub (@streams) {
        return Test::Mutation::Evidence::target( Test::Mutation::Record::parse( \@streams ), '/p/A.pm' );
    };
    is $evidence->()->{anomaly}, { reason => 'no-record', detail => 'the task produced no begin record' },
      'no process recorded the start of the test';
    is $evidence->("end\t24\n")->{anomaly},
      { reason => 'no-record', detail => 'a process ended without a begin record' },
      'an ending cannot stand for a start';
    is $evidence->("begin\t0\nend\t24\n")->{anomaly}, undef, 'an observed test can finish without loading the target';
    is $evidence->("begin\t0\noutside\t/p/B.pm\n")->{anomaly}, undef,
      'an outside load of another target stays separate';
    is $evidence->("begin\t0\noutside\t/p/A.pm\n")->{anomaly}{reason}, 'outside-copy', 'the project file was loaded';
    is $evidence->("begin\t0\naround\t/p/A.pm\n")->{anomaly}{reason},  'loaded-around-hook', 'the hook was bypassed';
    is $evidence->("begin\t0\nerror\t/p/A.pm\twriter failed\n")->{anomaly}{detail}, '/p/A.pm: writer failed',
      'the diagnostic survives into the verdict';
    my $missing = "seen\t/p/A.pm\tunresolved\n";
    my $at_exit = "seen\t/p/A.pm\tunresolved-at-exit\n";
    my $mixed   = Test::Mutation::Record::parse( [ $missing . $at_exit . "begin\t0\nseen\t/p/B.pm\nend\t24\n" ] );
    is Test::Mutation::Evidence::target( $mixed, '/p/B.pm' )->{unresolved}, 0,
      'an unresolved name belongs only to the target where Perl looked it up';
    is $mixed->{compiled}, { '/p/B.pm' => 1 }, 'records after the binding observation still identify compiled targets';
    is $evidence->( $missing . $at_exit )->{unresolved}, 1,     'the same interpreter observed both missing bindings';
    is $evidence->( $missing, $at_exit )->{unresolved},  0,     'independent interpreters cannot confirm each other';
    is $evidence->( $at_exit . $missing )->{unresolved}, 0,     'a later load cannot confirm a previous ending';
    is $evidence->( $missing . $at_exit )->{coverage},   undef, 'a function binding does not count as coverage';
    my $blind = $evidence->("begin\t1\nblind\t/p/A.pm\n");
    is $blind->{coverage}, { traced => 0, hits => {} }, 'a blind witness proves file coverage';
    is $blind->{load_failed}, 0, 'the witness ran during compilation';
    is $evidence->("begin\t1\nseen\t/p/A.pm\topened\n")->{load_failed}, 1,
      'an opened file still needs a compile witness';
    is $evidence->("begin\t1\nseen\t/p/A.pm\nseen\t/p/A.pm\tfailed\n")->{load_failed}, 1,
      'a failed load remains visible after a successful compilation';
    like dies { Test::Mutation::Evidence::target( Test::Mutation::Record::parse( [] ), [] ) }, qr/Str/,
      'a target must be a path string';
};

done_testing;
