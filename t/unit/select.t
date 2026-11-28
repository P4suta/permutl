use v5.36;
use Test2::V0;
use Cwd         ();
use Digest::SHA ();
use File::Temp  ();
use lib 't/e2e/lib', 't/lib';
use Fixture qw(copy_of with_driver_shims write_file);
use Raised;
use Test::Mutation::Merge;
use Test::Mutation::Select;
use Test::Mutation::Selection;
use Test::Mutation::Runner;
use Test::Mutation::Settings;

my $root  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my @files = qw(lib/A.pm lib/Nested/B.pm library/C.pm);
write_file( "$root/$_", "1;\n" ) for @files, 'lib/other.txt', 'lib/Time:Now.pm';
push @files, 'lib/Time:Now.pm';
write_file( "$root/lib/Nested/lib/Again.pm", "1;\n" );
push @files, 'lib/Nested/lib/Again.pm';

sub selection (@operands) {
    return Test::Mutation::Select::paths( $root, \@operands, \@files );
}

is selection(), {}, 'no operands';
is selection( 'lib/A.pm:1-2,4', './lib/A.pm:7' ),
  { 'lib/A.pm' => [ [ 1, 2 ], [ 4, 4 ], [ 7, 7 ] ] }, 'repeated file operands combine ranges';
is selection("$root/lib/A.pm"), { 'lib/A.pm' => [] }, 'an absolute file names the same project source';
my $directory = { map { $_ => [] } @files[ 0, 1, 3, 4 ] };
is selection('lib'), $directory, 'the directory stops at a path component boundary';
is selection( 'lib/A.pm:3', 'lib' ),        $directory, 'a directory expands a previous range to the entire file';
is selection( 'lib',        'lib/A.pm:3' ), $directory, 'a range leaves a previous complete file selection intact';
is selection( 'lib/A.pm',   'lib' ), $directory, 'an already selected file leaves later directory matches eligible';
is selection(q{.}),                { map { $_ => [] } @files }, 'the project directory includes every source';
is selection('lib/Time:Now.pm'),   { 'lib/Time:Now.pm' => [] },           'an existing filename can contain a colon';
is selection('lib/Time:Now.pm:3'), { 'lib/Time:Now.pm' => [ [ 3, 3 ] ] }, 'only the final colon introduces a range';

for my $operand ( q{}, qw(absent lib/other.txt lib:1 lib/A.pm: lib/A.pm:0 lib/A.pm:1-0 lib/A.pm:3-2 lib/A.pm:x),
    'lib/A.pm:1,' )
{
    my $error = Raised::error( sub { selection($operand) } );
    is $error->[1], 'path-selector-invalid', "refuse '$operand' as a selection";
    like $error->[2], qr/\Q$operand\E/, 'the diagnostic names the input';
}

subtest 'the selection carries matching files, mutants and the bytes that produced them' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $text    = "package Example;\r\nsub add { return \$_[0] + \$_[1] }\r\n1;\r\n";
    write_file( "$project/lib/Example.pm", $text );
    write_file( "$project/t/one.t",        "use Test::More tests => 1;\nok 1;\n" );
    my $resolve = sub (%settings) {
        return Test::Mutation::Select::resolve(
            config => Test::Mutation::Settings::of_call( { root => $project, %settings } ) );
    };
    is Raised::error( sub { $resolve->( source_exclude => ['t/one.t'] ) } )->[1], 'glob-unmatched',
      'an existing test outside the source selection cannot satisfy a source exclusion';
    is Raised::error( sub { $resolve->( test_exclude => ['lib/Example.pm'] ) } )->[1], 'glob-unmatched',
      'an existing source outside the test selection cannot satisfy a test exclusion';
    my $whole = $resolve->();
    is $whole->project, $project,    'the project is absolute';
    is $whole->tests,   ['t/one.t'], 'tests are project relative';
    is $whole->digests, { 'lib/Example.pm' => Digest::SHA::sha256_hex($text) },
      'the digest includes the original CRLF bytes';
    is $whole->narrowed, 0, 'defaults cover the project';
    is $whole->matches, {}, 'no explicit pattern was supplied';
    my ($add)  = grep { $_->description eq 'replaced + with -' } $whole->mutants->@*;
    my $prefix = substr $add->id, 0, 8;
    my $part   = $resolve->( source => ['lib/**/*.pm'], mutant => [ $prefix, $add->id ], shard => '2/2' );
    is $part->narrowed, 1, 'a chosen prefix narrows a measurement';
    is $part->matches,
      {
        source => { 'lib/**/*.pm' => ['lib/Example.pm'] },
        mutant => { $prefix       => [ $add->id ], $add->id => [ $add->id ] }
      },
      'the selection keeps the matches for every explicit request';
    is $part->inventory, { mutants => 1, digest => Digest::SHA::sha256_hex( $add->id ) },
      'both prefixes identify one mutant before sharding';
    is $part->mutants,                                              [], 'the other shard has no work';
    is $resolve->( source_exclude => ['lib/Example.pm'] )->mutants, [], 'a matched exclusion can remove every source';
    is Raised::error( sub { $resolve->( source => [ 'lib/Example.pm', 'lib/Gone.pm' ] ) } )->[1], 'glob-unmatched',
      'each explicit pattern must match';
    is Raised::error( sub { $resolve->( test_exclude => ['t/gone.t'] ) } )->[1], 'glob-unmatched',
      'an unmatched test exclusion fails as well';
    is Raised::error( sub { $resolve->( mutant => [ $add->id, 'z' ] ) } )->[1], 'mutant-unknown',
      'an earlier match cannot hide a bad prefix';
    my $clean    = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $defaults = Test::Mutation::Settings::of_call( { root => $clean } );
    is Test::Mutation::Select::resolve( config => $defaults )->mutants, [], 'the default globs may select nothing';
    my $explicit = Test::Mutation::Settings::of_call( { root => $clean, source => $defaults->source } );
    is Raised::error( sub { Test::Mutation::Select::resolve( config => $explicit ) } )->[1], 'glob-unmatched',
      'writing the default pattern explicitly requires a match';
    my $as_output = sub ( $format, $directory, $summary = undef ) {
        my $config = Test::Mutation::Settings::of_call(
            {
                root       => $project,
                format     => [ $format eq 'github' ? () : $format ],
                github     => $format eq 'github',
                report_dir => $directory
            }
        );
        return Test::Mutation::Select::resolve( config => $config, reports => 1, summary => $summary );
    };
    is Raised::error( sub { $as_output->( 'json', 'lib/Example.pm/reports' ) } )->[1], 'directory-uncreatable',
      'an ordinary file cannot contain the report directory';
    is Raised::error( sub { $as_output->( 'github', 'reports', 'absent/summary.md' ) } )->[1], 'file-unwritable',
      'the summary must have an existing writable parent';
    is $as_output->( 'json', 'future/nested' )->inventory, $whole->inventory, 'a future report directory is valid';
    ok !-e "$project/future", 'validation creates no directory';
    {
        local $ENV{PATH} = 'tools';
        my $program = "$project/tools/perl-under-test";
        write_file( $program, "#!$^X\nprint \$];\n" );
        chmod 0755, $program or die "chmod: $!";
        is $resolve->( perl => 'perl-under-test' )->perl, $program, 'relative PATH entries follow the project root';
        write_file( $program, "#!$^X\nprint '5.008009';\n" );
        is Raised::error( sub { $resolve->( perl => 'perl-under-test' ) } )->[1], 'interpreter-invalid',
          'the test interpreter must support the Perl 5.10 shim';
        write_file( $program, "#!$^X\nexit 1 if exists \$ENV{PERL5OPT}; print '5.010000';\n" );
        local $ENV{PERL5OPT} = '-Mstrict';
        is $resolve->( perl => 'perl-under-test' )->perl, $program,
          'the supported lower boundary is probed without loading application switches';
    }
    $whole->verify_copy($project);
    my @phases;
    my $failure = Raised::error(
        sub {
            Test::Mutation::Runner::run(
                Test::Mutation::Settings::of_call( { root => $project } ),
                sub ( $event, $data ) {
                    return if $event ne 'phase';
                    push @phases, $data->{name};
                    write_file( "$project/lib/Example.pm", $text =~ s/\+/-/r ) if $data->{name} eq 'acquire';
                }
            );
        }
    );
    is [ $failure->@[ 0, 1 ] ], [ 'environment', 'source-changed' ],
      'a same-length change between analysis and copy stops the run';
    ok !grep( { $_ eq 'baseline' } @phases ), 'no test starts on different bytes';
    is $phases[-1], 'release', 'the failed copy releases its workspace';
};

subtest 'a report identifies the requested lines and the inputs that support them' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $first   = 'lib/A.pm';
    my $chosen  = 'lib/Z.pm';
    write_file( "$project/$first",   "package A;\nsub one { return 1 + 1 }\n1;\n" );
    write_file( "$project/$chosen",  "package Z;\nsub two { return 2 + 2 }\n1;\n" );
    write_file( "$project/t/pass.t", "use Test::More tests => 1;\nok 1;\n" );
    my %rules;
    for my $cache ( 0, 1 ) {
        for my $reports ( 0, 1 ) {
            my $config   = Test::Mutation::Settings::of_call( { root => $project, cache => $cache } );
            my $selected = Test::Mutation::Select::resolve(
                config   => $config,
                operands => ["$chosen:2"],
                reports  => $reports
            );
            is $selected->selection, { paths => { $chosen => [ [ 2, 2 ] ] } }, 'the report retains the requested range';
            is [ sort keys $selected->sources->%* ], [$chosen], 'an earlier file cannot hide the selected source';
            is [ sort keys $selected->digests->%* ], $cache || $reports ? [ $first, $chosen ] : [$chosen],
              "cache $cache and reports $reports retain the required input digests";
            $rules{ $selected->analysis_rules_digest }++;
        }
    }
    is [ values %rules ], [4], 'all four selections use the same analysis rules';
    my $whole = Test::Mutation::Select::resolve( config => Test::Mutation::Settings::of_call( { root => $project } ) );
    my %attributes = $whole->%*;
    delete $attributes{selection};
    is Test::Mutation::Selection->new(%attributes)->selection, {},
      'an unfiltered selection constructed without an explicit filter records the whole project';
    delete $attributes{analysis_rules_digest};
    is Test::Mutation::Selection->new(%attributes)->analysis_rules_digest, $whole->catalog_digest,
      'a selection supplied without separate analysis rules retains its catalog identity';
};

subtest 'a prepared shard and a resolved shard can measure the same source lines' => sub {
    my $project = copy_of('calc');
    write_file( "$project/lib/Other.pm", "package Other; 1;\n" );
    my $paths = { 'lib/Calc.pm' => [ [ 7, 7 ] ] };
    my ( $first_config, $peer_config ) =
      map { Test::Mutation::Settings::of_call( { root => $project, shard => "$_/2", cache => $_ - 1 } ); } 1, 2;
    my $run = sub ( $config, $scope ) {
        return with_driver_shims(
            sub {
                Test::Mutation::Runner::run( $config, sub { }, $scope );
            }
        );
    };
    my $peer    = $run->( $peer_config, { paths => $paths } );
    my $measure = sub ( $selection, $config ) {
        my %inputs = $selection->%*;
        delete $inputs{analysis_rules_digest};
        my $prepared = Test::Mutation::Selection->new(%inputs);
        return $run->( $config, { selection => $prepared } );
    };
    my $selected = Test::Mutation::Select::resolve( config => $first_config, paths => $paths );
    my $merge    = sub ( $part, $other ) {
        return Test::Mutation::Merge::merge(
            [ { name => 'prepared', result => $part }, { name => 'peer', result => $other } ] );
    };
    my $part   = $measure->( $selected, $first_config );
    my $merged = $merge->( $part, $peer );
    is scalar( $merged->entries->@* ), $selected->inventory->{mutants}, 'both parts restore the selected inventory';
    ok $merged->tally->{counts}{Killed}, 'the merged report contains an observed test failure';
    my $previous;
    {
        local $Test::Mutation::Select::ANALYSIS_REVISION = $Test::Mutation::Select::ANALYSIS_REVISION - 1;
        $previous = Test::Mutation::Select::resolve( config => $first_config, paths => $paths );
    }
    my $old_part = $measure->( $previous, $first_config );
    like dies { $merge->( $old_part, $peer ) }, qr/measurement inputs differ/,
      'a catalog from an earlier analyzer revision cannot identify the current rules';
    my $strict = Test::Mutation::Settings::of_call(
        { root => $project, shard => '2/2', cache => 1, suppress_require_reason => 1 } );
    my $other_rules = Test::Mutation::Select::resolve( config => $strict, paths => $paths );
    my $strict_peer = $measure->( $other_rules, $peer_config );
    like dies { $merge->( $part, $strict_peer ) }, qr/measurement inputs differ/,
      'a different suppression policy cannot identify the current rules';
    like dies { $merge->( $old_part, $strict_peer ) }, qr/measurement inputs differ/,
      'shards from two different prepared catalogs retain their own identities';
};

done_testing;
