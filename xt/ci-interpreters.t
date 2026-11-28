use v5.36;
use Test2::V0;
use CPAN::Meta::YAML ();
use Cwd              ();
use File::Temp       ();
use TOML::Tiny       ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Gate;
use Test::Mutation::Source ();

my $workflow = CPAN::Meta::YAML->read('.github/workflows/check.yml')->[0];
my $tasks    = TOML::Tiny::from_toml( Test::Mutation::Source::read_bytes('mise.toml') )->{tasks};
is $tasks->{'check-ci-interpreters'}{run}, 'perl xt/bin/check-ci-interpreters',
  'the interpreter checks are available locally';
ok scalar( grep { $_ eq 'mise run check-ci-interpreters' } $tasks->{'release-compatibility'}{run}->@* ),
  'recording a release includes the interpreter matrix';

my $scratch = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $docker  = write_file( "$scratch/docker", <<'SH' );
#!/bin/sh
set -eu
printf '%s\t' "$@" >> "$CHECK_LOG"
printf '\n' >> "$CHECK_LOG"
case "$1" in
    build) printf 'sha256:%064d\n' 1 ;;
    run) exit "${CHECK_EXIT:-0}" ;;
    *) exit 2 ;;
esac
SH
chmod oct '755', $docker or die "make the test Docker executable: $!";
local $ENV{PATH}      = "$scratch:$ENV{PATH}";
local $ENV{CHECK_LOG} = "$scratch/commands";
write_file( $ENV{CHECK_LOG}, q{} );
is system( $^X, 'xt/bin/check-ci-interpreters' ), 0, 'all interpreter checks ran';

my @commands = map { [ split /\t/ ] } split /\n/, Test::Mutation::Source::read_bytes( $ENV{CHECK_LOG} );
my %matrix   = map { $_ => $workflow->{jobs}{$_}{strategy}{matrix} } qw(driver shim);
my @cases    = ( map { [ 'driver', $_->{perl}, $_->{require} ] } $matrix{driver}{include}->@* );
push @cases, map { [ 'shim', $_, 'toolchain' ] } $matrix{shim}{perl}->@*;
is scalar @commands, 2 * @cases, 'each hosted interpreter has a local build and a local run';
Gate::checked( 'Linux interpreter runs', scalar( grep { $_->[0] eq 'run' } @commands ), at_least => 8 );
for my $case (@cases) {
    my ( $kind, $version, $require ) = @$case;
    my $base  = 'perl' . ( $version =~ s/[.]//gr );
    my $build = shift @commands || [];
    my $run   = shift @commands || [];
    is $build->[0], 'build', "build the $kind on Perl $version";
    ok scalar( grep { $_ eq "CHECK_PERL=$base" } @$build ), 'build the selected interpreter';
    ok scalar( grep { $_ eq "check-$kind" } @$build ),      'select the driver or shim dependencies';
    is $run->[0], 'run', 'execute the built image';
    ok scalar( grep { $_ eq '--init' } @$run ), 'reap orphaned test processes as a hosted runner does';
    ok scalar( grep { $_ eq "TEST_MUTATION_REQUIRE=$require" } @$run ), 'require every hosted capability';
    my $script    = $workflow->{jobs}{$kind}{steps}[-1]{run};
    my @arguments = split q{ }, $script;
    is [ @$run[ -@arguments .. -1 ] ], \@arguments, 'run the hosted test command';
}
subtest 'the matrix rejects a failing interpreter' => sub {
    local $ENV{CHECK_EXIT} = 9;
    write_file( $ENV{CHECK_LOG}, q{} );
    isnt system( $^X, 'xt/bin/check-ci-interpreters' ), 0, 'one failing interpreter fails the local gate';
    my @attempts = split /\n/, Test::Mutation::Source::read_bytes( $ENV{CHECK_LOG} );
    is scalar @attempts, 2, 'the first failed interpreter stops the remaining work';
};
done_testing;
