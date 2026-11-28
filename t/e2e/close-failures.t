use v5.36;
use Test2::V0;
use Cwd        ();
use File::Copy ();
use File::Temp ();

# A close that fails means lost data or an unread error, so the run and the command check every close.
# The override below closes the handle and then reports a failure to the subroutine that the pattern names.
our $failing;    ## no critic (Variables::ProhibitPackageVars)

BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::close = sub : prototype(;*) (@handle) {
        my $closed = @handle ? CORE::close( $handle[0] ) : CORE::close();
        my $caller = ( caller 1 )[3] || 'main';
        return $closed if !defined $failing || $caller !~ $failing;
        $! = 5;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return !1;
    };
}

use lib 't/e2e/lib', 't/lib';
use Fixture qw(copy_of leftovers run_fixture with_driver_shims);
use Test::Mutation::CLI;
use Test::Mutation::Settings;
use Test::Mutation::Runner;

sub failing_in ( $pattern, $code ) {
    local $failing = $pattern;
    return $code->();
}

my $root = copy_of('calc');

like dies {
    failing_in( qr/::Source::read_bytes\z/,
        sub { Test::Mutation::Runner::analyze( Test::Mutation::Settings::of_call( { root => $root } ) ) } )
},
  qr/\Acannot close \Q$root\E\/lib\/Calc[.]pm: /,
  'a source file that does not close stops the analysis';
like dies {
    failing_in( qr/::Runner::_spew\z/, sub { run_fixture($root) } )
}, qr/\Acannot close \S+: /, 'a work file that does not close stops the run';
like dies {
    failing_in( qr/::Runner::_first_line\z/, sub { run_fixture($root) } )
}, qr/\Acannot close t\/\w+[.]t: /, 'a test file that does not close stops the run';

my $analysis = Test::Mutation::Runner::analyze( Test::Mutation::Settings::of_call( { root => $root } ) );
my $mutant   = $analysis->{mutants}[0];
like dies {
    failing_in(
        qr/::Runner::_spew\z/,
        sub {
            Test::Mutation::Runner::run_command(
                Test::Mutation::Settings::of_call( { root => $root } ),
                $analysis->{sources}{ $mutant->path },
                $mutant, [ $^X, '-e', '1' ]
            );
        }
    )
}, qr/\Acannot close \S+: /, 'a work file that does not close stops a command with a mutant';
is leftovers( File::Temp::tempdir( CLEANUP => 1 ), $root ), [], 'and the command leaves no work directory';

sub command (@arguments) {
    my $here = Cwd::getcwd();
    my ( $output, $errors ) = ( q{}, q{} );
    chdir $root or die "chdir: $!";
    my $status = do {
        local *STDOUT;    ## no critic (Variables::RequireInitializationForLocalVars)
        local *STDERR;    ## no critic (Variables::RequireInitializationForLocalVars)
        open STDOUT, '>', \$output or die "stdout: $!";
        open STDERR, '>', \$errors or die "stderr: $!";
        with_driver_shims( sub { Test::Mutation::CLI::main(@arguments) } );
    };
    chdir $here or die "chdir: $!";
    return ( $status, $errors, $output );
}

for my $part ( 1, 2 ) {
    my ($status) = command( 'run', '--shard', "$part/2", '--report-dir', "part$part", '--format', 'json', '--jobs', 2 );
    is $status, 0, "part $part runs";
}
my @reports = ( 'part1/mutation.json', 'part2/mutation.json' );
{
    mkdir "$root/invalid-report"               or die $!;
    mkdir "$root/invalid-report/mutation.json" or die $!;
    my ( $exit, $diagnostic, $output ) =
      command( 'merge', @reports, '--format', 'terminal', '--format', 'json', '--report-dir', 'invalid-report' );
    is [ $exit, $output ], [ 5, q{} ], 'an unusable merge output is refused before publishing the terminal report';
    like $diagnostic, qr/cannot write .*mutation[.]json/, 'the refusal names the destination';
}

my ( $status, $errors ) = failing_in( qr/::CLI::_read_report\z/, sub { command( 'merge', @reports ) } );
is [ $status, $errors =~ s/: [^:\n]+\n\z//r ], [ 5, 'mutation: cannot close part1/mutation.json' ],
  'a report that does not close is an error of the environment';

{
    mkdir "$root/scoped"                                                          or die $!;
    File::Copy::copy( "$root/part1/mutation.json", "$root/scoped/mutation.json" ) or die $!;
    my ( $exit, $diagnostic ) = failing_in( qr/::CLI::_previous_report\z/,
        sub { command( 'run', '--mutant', $mutant->id, '--format', 'json', '--report-dir', 'scoped', '--jobs', 1 ) } );
    is $exit, 0, 'a narrow measurement can replace an earlier report without reading it';
    unlike $diagnostic, qr/cannot close/, 'publication only opens the output';

    mkdir "$root/nonfile"               or die $!;
    mkdir "$root/nonfile/mutation.html" or die $!;
    my ($published) = failing_in( qr/::CLI::_previous_report\z/,
        sub { command( 'run', '--mutant', $mutant->id, '--format', 'json', '--report-dir', 'nonfile', '--jobs', 1 ) } );
    is $published, 0, 'a directory named like a report is skipped without opening it';

}

( $status, $errors ) =
  failing_in( qr/::CLI::_publish_report\z/,
    sub { command( 'merge', @reports, '--format', 'json', '--report-dir', 'whole' ) } );
is [ $status, $errors =~ s/: [^:\n]+\n\z//r ], [ 5, 'mutation: cannot close whole/mutation.json' ],
  'a report file that does not close after the write fails the command';

{
    my ( $exit, $diagnostic, $output ) = failing_in( qr/::CLI::_file_reports\z/,
        sub { command( 'merge', @reports, '--format', 'json', '--report-dir', 'whole' ) } );
    is [ $exit, $diagnostic =~ s/: [^:\n]+\n\z//r, $output ], [ 5, 'mutation: cannot close whole', q{} ],
      'the command reports a failed release of the report lock before announcing the files';
}

{
    local $ENV{GITHUB_STEP_SUMMARY} = "$root/summary.md";
    ( $status, $errors ) = failing_in( qr/::CLI::_report_to_github\z/,
        sub { command( 'merge', @reports, '--format', 'terminal', '--github' ) } );
    is [ $status, $errors =~ s/: [^:\n]+\n\z//r ], [ 5, "mutation: cannot close $root/summary.md" ],
      'a job summary that does not close fails the command';
}

done_testing;
