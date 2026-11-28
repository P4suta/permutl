use v5.36;
use Test2::V0;
use CPAN::Meta::YAML ();
use Cwd              ();
use ExtUtils::MM     ();
use File::Temp       ();
use JSON::PP         ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Gate;
use Test::Mutation::Mutator::Catalog ();
use Test::Mutation::Settings         ();

my $workflow = CPAN::Meta::YAML->read('.github/workflows/release-gate.yml')->[0];
my $jobs     = $workflow->{jobs};
my $scratch  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );

sub executable ( $path, $text ) {
    write_file( $path, $text );
    chmod oct '755', $path or die "make the command executable: $!";
    return;
}

sub step ( $job, $pattern ) {
    my ($entry) = grep { ( $_->{run} || q{} ) =~ $pattern } ( $job->{steps} || [] )->@*;
    return $entry ? $entry->{run} : q{};
}

subtest 'the release rejects mutable sources and controllers outside main' => sub {
    for my $input (qw(source_sha version)) {
        is $workflow->{on}{workflow_call}{inputs}{$input}{required}, 'true',   "callers must supply $input";
        is $workflow->{on}{workflow_dispatch}{inputs}{$input}{type}, 'string', "a rehearsal can choose $input";
    }
    my $script = step( $jobs->{candidate}, qr/GITHUB_REF/ );
    ok length($script), 'the workflow validates the source before checking it out' or return;
    local $ENV{GITHUB_REF}    = 'refs/heads/main';
    local $ENV{SOURCE_SHA}    = 'a' x 40;
    local $ENV{REF_PROTECTED} = 'true';
    is system( 'bash', '-eu', '-c', $script ), 0, 'main can choose an immutable commit';
    {
        local $ENV{REF_PROTECTED} = 'false';
        isnt system( 'bash', '-eu', '-c', $script ), 0, 'the controller requires protected main';
    }
    {
        local $ENV{SOURCE_SHA} = 'main';
        isnt system( 'bash', '-eu', '-c', $script ), 0, 'a mutable candidate ref is refused';
    }
    local $ENV{GITHUB_REF} = 'refs/heads/other';
    isnt system( 'bash', '-eu', '-c', $script ), 0, 'a workflow dispatched outside main is refused';
};

subtest 'protected controller code verifies the local status before reading candidate files' => sub {
    my $candidate = $jobs->{candidate};
    is $candidate->{permissions}, { contents => 'read', statuses => 'read' },
      'the identity job only reads commits and their statuses';
    my @steps = $candidate->{steps}->@*;
    my ($control) = grep { ( $steps[$_]{with}{path} || q{} ) eq 'controller' } keys @steps;
    my ($check) =
      grep { ( $steps[$_]{run} || q{} ) eq 'bash controller/xt/bin/verify-local-release-check' } keys @steps;
    my ($source) = grep { ( $steps[$_]{with}{ref} || q{} ) eq q{${{ env.SOURCE_SHA }}} } keys @steps;
    my $has_steps = defined $control && defined $check && defined $source;
    ok $has_steps, 'the candidate job runs the controller and reads the candidate separately'
      or return;
    ok $control < $check && $check < $source, 'local status approval precedes every candidate checkout';
    is $steps[$control]{with}{ref}, q{${{ github.workflow_sha }}},
      'the verifier belongs to the calling workflow revision';
    is $steps[$control]{with}{'persist-credentials'}, 'false', 'the controller checkout keeps no credential';
    is $steps[$check]{env}{REPOSITORY_OWNER_ID}, q{${{ github.repository_owner_id }}},
      'GitHub supplies the trusted account ID';
    is $steps[$check]{env}{GH_TOKEN},       q{${{ github.token }}}, 'only the verifier step receives the status token';
    is $steps[$check]{'continue-on-error'}, undef,                  'a failed status check stops the job';
};

subtest 'the release configuration measures guarded exits' => sub {
    my $config   = Test::Mutation::Settings::of_call( { root => q{.} } );
    my $mutators = Test::Mutation::Mutator::Catalog::choose(
        profile => $config->profile,
        enable  => $config->enable,
        disable => $config->disable
    );
    ok scalar( grep { $_->name eq 'early-exit' } @$mutators ), 'the project enables guarded exit removal';
};

subtest 'each platform and the identity job check out the selected commit' => sub {
    for my $job (qw(candidate release macos)) {
        my ($checkout) =
          grep { ( $_->{uses} || q{} ) =~ m{\Aactions/checkout@} && ( $_->{with}{path} || q{} ) ne 'controller' }
          ( $jobs->{$job}{steps} || [] )->@*;
        is $checkout->{with}{ref},                   q{${{ env.SOURCE_SHA }}}, "$job reads the selected commit";
        is $checkout->{with}{'persist-credentials'}, 'false', "$job leaves no credentials in the checkout";
    }
};

subtest 'candidate tools stay out of the shared Actions cache' => sub {
    my @tools = map {
        grep { ( $_->{uses} || q{} ) =~ m{\Ajdx/mise-action@} }
          $_->{steps}->@*
    } values %$jobs;
    is scalar @tools,     2,       'both distribution builds install the pinned tools';
    is $_->{with}{cache}, 'false', 'the tool installation reads and writes no shared cache' for @tools;
};

subtest 'the candidate rejects a different version or checkout' => sub {
    my $script = step( $jobs->{candidate}, qr/git rev-parse HEAD/ );
    ok length($script), 'candidate identity comes from the checkout' or return;
    chomp( my $revision = qx{git rev-parse HEAD} );
    my $version = ExtUtils::MM->parse_version('lib/Test/Mutation.pm');
    local $ENV{GITHUB_OUTPUT} = "$scratch/identity";
    local $ENV{SOURCE_SHA}    = $revision;
    local $ENV{VERSION}       = $version;
    is system( 'bash', '-eu', '-c', $script ), 0, 'the declared version matches the selected commit';
    open my $identity, '<', $ENV{GITHUB_OUTPUT} or die "read the candidate identity: $!";
    chomp( my @values = readline $identity );
    close $identity or die "close the candidate identity: $!";
    is \@values, [ "source_sha=$revision", "version=$version" ], 'only the verified source and version are exported';
    {
        local $ENV{SOURCE_SHA} = '0' x 40;
        isnt system( 'bash', '-eu', '-c', $script ), 0, 'a different checkout is refused';
    }
    local $ENV{VERSION} = "$version.99";
    isnt system( 'bash', '-eu', '-c', $script ), 0, 'a different release version is refused';
};

subtest 'the hosted gate builds and installs the selected distribution on both platforms' => sub {
    is [ sort keys %$jobs ], [qw(candidate macos release verified)],
      'hosted jobs check identity, build twice and verify the artifact';
    for my $job (qw(release macos)) {
        is $jobs->{$job}{needs}, 'candidate', "$job waits for the local checks";
        my @commands = map { $_->{run} } grep { ( $_->{run} || q{} ) =~ /\bmise\s/ } $jobs->{$job}{steps}->@*;
        is \@commands, [ 'mise run setup', 'mise run dist', 'mise run verify-install' ],
          "$job builds and installs the archive";
        my ($install) = grep { ( $_->{run} || q{} ) eq 'mise run verify-install' } $jobs->{$job}{steps}->@*;
        my $archive =
          $job eq 'release'
          ? q{${{ steps.tested.outputs.archive }}}
          : q{Test-Mutation-${{ needs.candidate.outputs.version }}.tar.gz};
        is $install->{env}{TEST_MUTATION_DISTRIBUTION}, $archive, "$job installs the named candidate archive";
    }
};

subtest 'the verified output waits for both platforms and names one immutable artifact' => sub {
    my $verified = $jobs->{verified} || {};
    is $verified->{needs}, '[candidate, release, macos]', 'both tested platforms gate the artifact';
    for my $field (qw(source_sha version archive_name archive_sha256 artifact_id)) {
        is $workflow->{on}{workflow_call}{outputs}{$field}{value}, "\${{ jobs.verified.outputs.$field }}",
          "callers receive the verified $field";
    }
    my ($upload) = grep { ( $_->{uses} || q{} ) =~ m{\Aactions/upload-artifact@} } $jobs->{release}{steps}->@*;
    is $upload->{with}{name}, q{cpan-${{ env.SOURCE_SHA }}-${{ github.run_id }}-${{ github.run_attempt }}},
      'the artifact name binds the build commit, run and attempt';
    my ($install) = grep { ( $_->{run} || q{} ) eq 'mise run verify-install' } $jobs->{release}{steps}->@*;
    is $upload->{with}{path}, $install->{env}{TEST_MUTATION_DISTRIBUTION}, 'the upload uses the installed archive path';
    ok $upload->{with}{path}, 'the install and upload select one archive';
    my ($download) = grep { ( $_->{uses} || q{} ) =~ m{\Aactions/download-artifact@} } ( $verified->{steps} || [] )->@*;
    is $download->{with}{'artifact-ids'}, q{${{ needs.release.outputs.artifact_id }}},
      'verification reads the uploaded ID';
    is $download->{with}{'digest-mismatch'}, 'error', 'a transport digest mismatch fails verification';
    my ($controller) = grep { ( $_->{with}{path} || q{} ) eq 'controller' } ( $verified->{steps} || [] )->@*;
    is $controller->{with}{ref}, q{${{ github.workflow_sha }}}, 'archive verification runs the trusted controller';
    my $recheck = $verified->{steps}[-1];
    is $recheck->{run}, 'bash controller/xt/bin/verify-local-release-check',
      'a status change during either build can still stop publication';
    is $verified->{permissions}{statuses}, 'read', 'the artifact verifier reads commit statuses';
    is $recheck->{env}{REPOSITORY_OWNER_ID}, q{${{ github.repository_owner_id }}},
      'the artifact verifier uses the same account identity';
    is $recheck->{env}{GH_TOKEN}, q{${{ github.token }}}, 'the final check receives a read token';
};

subtest 'a retried verification rejects artifacts from other builds' => sub {
    my $script = step( $jobs->{verified}, qr/gh api/ );
    ok length($script), 'the verifier checks a GitHub artifact receipt' or return;
    executable( "$scratch/bin/gh", "#!/bin/sh\nprintf '%s\\n' \"\$RECEIPT\"\n" );
    local $ENV{PATH}               = "$scratch/bin:$ENV{PATH}";
    local $ENV{SOURCE_SHA}         = 'ab' x 20;
    local $ENV{ARTIFACT_ID}        = 55;
    local $ENV{GITHUB_REPOSITORY}  = 'fixture/distribution';
    local $ENV{GITHUB_RUN_ID}      = 11;
    local $ENV{GITHUB_RUN_ATTEMPT} = 2;
    local $ENV{BUILD_ATTEMPT}      = 1;
    my %receipt = (
        name         => "cpan-$ENV{SOURCE_SHA}-11-1",
        id           => 55,
        workflow_run => { id => 11 },
        expired      => JSON::PP::false,
    );
    local $ENV{RECEIPT} = JSON::PP->new->encode( \%receipt );
    is system( 'bash', '-euo', 'pipefail', '-c', $script ), 0,
      'retrying macOS can reuse the exact successful Linux artifact';

    for my $mismatch ( [ id => 56 ], [ workflow_run => { id => 12 } ], [ expired => JSON::PP::true ],
        [ name => 'other' ] )
    {
        local $ENV{RECEIPT} = JSON::PP->new->encode( { %receipt, @$mismatch } );
        isnt system( 'bash', '-euo', 'pipefail', '-c', $script ), 0, 'a conflicting receipt is rejected';
    }
};

Gate::checked( 'release jobs', scalar keys %$jobs, at_least => 4 );
done_testing;
