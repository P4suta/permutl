use v5.36;
use Test2::V0;
use YAML::PP   ();
use File::Temp ();
use lib 't/lib';
use Gate;

my $path = '.github/workflows/publish-cpan.yml';
ok -f $path, 'the Perl publication workflow exists' or bail_out('missing publication workflow');
my $workflow = YAML::PP->new( schema => ['Failsafe'] )->load_file($path);
my $gate     = $workflow->{jobs}{verify};
my $job      = $workflow->{jobs}{publish};
my @steps    = $job->{steps}->@*;
my %steps    = map { $_->{id} => $_ } grep { exists $_->{id} } @steps;
my $source   = 'f1' x 20;
my $temp     = File::Temp::tempdir( CLEANUP => 1 );

sub select_candidate (%extra) {
    local %ENV = (
        %ENV,
        CPAN_SOURCE_SHA   => $source,
        VERIFIED_SOURCE   => $source,
        CPAN_VERSION      => '0.001',
        VERIFIED_VERSION  => '0.001',
        CPAN_ARCHIVE_NAME => 'Test-Mutation-0.001.tar.gz',
        ARTIFACT_ID       => '123',
        RUNNER_TEMP       => $temp,
        GITHUB_ENV        => "$temp/env",
        %extra,
    );
    return system( 'bash', '-eu', '-o', 'pipefail', '-c', $steps{candidate}{run} ) == 0;
}

subtest 'the release call verifies the selected source without a publication credential' => sub {
    is [ sort keys $workflow->{on}->%* ], ['workflow_call'], 'publication requires a release caller';
    is [ sort keys $workflow->{on}{workflow_call}{inputs}->%* ], [qw(release_id source_sha tag version)],
      'the caller selects the source, version, tag and draft';
    is $gate->{uses}, './.github/workflows/release-gate.yml', 'the full repository release gate checks the candidate';
    is $gate->{with}{source_sha}, '${{ inputs.source_sha }}', 'verification checks the requested commit';
    is $gate->{with}{version},    '${{ inputs.version }}',    'verification checks the selected Perl version';
    is $gate->{permissions}, { actions => 'read', contents => 'read', statuses => 'read' },
      'the publication caller grants read access to artifacts, commits and local statuses';
    my $proposal = YAML::PP->new( schema => ['Failsafe'] )->load_file('.github/workflows/release-please.yml');
    is $proposal->{jobs}{publish}{permissions}{statuses}, 'read',
      'the upstream reusable workflow grants access to local statuses';
    ok !exists $gate->{secrets}, 'candidate execution receives no environment credential';
    like $gate->{if}, qr{github[.]ref == 'refs/heads/main'}, 'the trusted workflow runs from main';
    like $gate->{if}, qr{github[.]ref_protected},            'publication requires branch protection';
    is $job->{needs},       'verify', 'the publishing job depends on all candidate checks';
    is $job->{environment}, 'cpan',   'only the publisher receives the publication environment';
};

subtest 'publication rejects a mismatched source or distribution artifact' => sub {
    my ($checkout) = grep { exists $_->{uses} && $_->{uses} =~ m{\Aactions/checkout@} } @steps;
    is $checkout->{with}{ref},                   '${{ github.sha }}', 'publication code comes from protected main';
    is $checkout->{with}{'persist-credentials'}, 'false',             'the checkout saves no deployment credentials';
    my ($download) = grep { exists $_->{uses} && $_->{uses} =~ m{\Aactions/download-artifact@} } @steps;
    is $download->{with}{'artifact-ids'}, '${{ needs.verify.outputs.artifact_id }}',
      'the workflow downloads the verified artifact';
    is $job->{env}{CPAN_ARCHIVE_SHA256}, '${{ needs.verify.outputs.archive_sha256 }}',
      'the expected digest comes from the release gate';
    ok select_candidate(), 'the release job admits the matching source and archive';
    for my $case (
        [ VERIFIED_SOURCE   => 'd2' x 20 ],
        [ VERIFIED_VERSION  => '0.002' ],
        [ CPAN_ARCHIVE_NAME => 'another.tar.gz' ],
        [ ARTIFACT_ID       => q{} ],
      )
    {
        ok !select_candidate( $case->@* ), "the release job rejects a mismatched $case->[0]";
    }
};

subtest 'only a newly reserved submission can send the Perl archive' => sub {
    is [ map { $_->{id} } grep { exists $_->{id} } @steps ],
      [qw(candidate stage credential preflight claim submit reconcile finish)],
      'verify, stage and preflight the archive before reserving the upload';
    is $steps{credential}{if}, q{steps.stage.outputs.action == 'prepare'},
      'an existing reservation skips the upload credential';
    is $steps{preflight}{if}, $steps{credential}{if}, 'a first submission checks the credential';
    is $steps{claim}{if},     $steps{credential}{if}, 'a first submission reserves the archive after preflight';
    is $steps{submit}{if}, q{steps.claim.outputs.action == 'submit'},
      'only the job that created the reservation may submit';
    is [ map { $_->{id} } grep { exists $_->{env}{PAUSE_TOKEN} } @steps ], [qw(preflight submit)],
      'only preflight and submission receive the upload token';
    is $steps{credential}{with}{ 'inject-env-vars' }, 'false',
      'the secret provider does not export tokens into later steps';
    like $steps{reconcile}{run}, qr/pause reconcile/, 'recovery checks the public bytes';
    like $steps{finish}{run}, qr/draft finish/,
      'the release controller rechecks the registry before making the release public';
};

Gate::checked( 'publication steps', scalar keys %steps, at_least => 8 );
done_testing;
