use v5.36;
use Test2::V0;
use File::Temp ();
use JSON::PP   ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Gate;

my $dir    = File::Temp::tempdir( CLEANUP => 1 );
my $repo   = 'P4suta/Test-Mutation';
my $owner  = 42543015;
my $source = 'ab' x 20;
my $head   = 'cd' x 20;
my $tree   = 'ef' x 20;
my $pass   = { context => 'release/local', state => 'success', creator => { id => $owner } };
my $json   = JSON::PP->new;

write_file( "$dir/gh", <<'PERL' );
#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP ();
my $path = pop @ARGV;
my $pages = $path =~ m{/statuses[?]per_page=100\z} ? 1 : 0;
die "unexpected gh arguments: @ARGV" unless "@ARGV" eq ( $pages ? 'api --paginate --slurp' : 'api' );
my $responses = JSON::PP::decode_json( $ENV{CHECK_RESPONSES} );
die "unexpected API request: $path" unless exists $responses->{$path};
print JSON::PP::encode_json( $responses->{$path} );
exit( $path eq ( $ENV{FAILED_REQUEST} || q{} ) ? 1 : 0 );
PERL
chmod oct('755'), "$dir/gh" or die "chmod gh: $!";

sub statuses ($sha) { return "repos/$repo/commits/$sha/statuses?per_page=100" }
sub commit   ($sha) { return "repos/$repo/git/commits/$sha" }

sub admits ( $responses, $event = {}, %env ) {
    write_file( "$dir/event.json", $json->encode($event) );
    local %ENV = (
        %ENV,
        PATH                => "$dir:$ENV{PATH}",
        SOURCE_SHA          => $source,
        GITHUB_SHA          => $source,
        GITHUB_REPOSITORY   => $repo,
        GITHUB_EVENT_NAME   => 'workflow_dispatch',
        GITHUB_EVENT_PATH   => "$dir/event.json",
        REPOSITORY_OWNER_ID => $owner,
        CHECK_RESPONSES     => $json->encode($responses),
        %env
    );
    return system( 'bash', 'xt/bin/verify-local-release-check' ) == 0;
}

subtest 'the candidate rejects stale or unauthorized release statuses' => sub {
    my $endpoint = statuses($source);
    my $other    = { %$pass, context => 'other', state => 'failure' };
    ok admits( { $endpoint => [ [$other], [$pass] ] } ), 'a successful status on a later page approves the candidate';
    my @updates =
      ( { %$pass, state => 'failure' }, { %$pass, state => 'pending' }, { %$pass, creator => { id => $owner + 1 } }, );
    for my $update (@updates) {
        ok !admits( { $endpoint => [ [ $update, $pass ] ] } ), 'an older success cannot replace the latest status';
    }
    Gate::checked( 'superseding status updates', scalar @updates, at_least => 3 );
    ok !admits( { $endpoint => [ [$other] ] } ), 'a manual rehearsal requires the selected commit to pass';
    ok !admits( { $endpoint => [ [$pass] ] }, {}, FAILED_REQUEST => $endpoint ),
      'an API failure invalidates even a partial success response';
};

sub merged_event () {
    return {
        action       => 'closed',
        repository   => { full_name => $repo },
        pull_request => {
            state            => 'closed',
            merged           => JSON::PP::true,
            merge_commit_sha => $source,
            user             => { type => 'Bot', id => 297731343 },
            head => { repo => { full_name => $repo }, ref => 'release-please--branches--main', sha => $head },
            base => { repo => { full_name => $repo }, ref => 'main' },
        }
    };
}

subtest 'a merged release proposal can carry approval only across identical Git trees' => sub {
    my %answers = (
        statuses($source) => [ [] ],
        statuses($head)   => [ [$pass] ],
        commit($source)   => { sha => $source, tree => { sha => $tree } },
        commit($head)     => { sha => $head,   tree => { sha => $tree } },
    );
    my %trigger = ( GITHUB_EVENT_NAME => 'pull_request' );
    ok admits( \%answers, merged_event(), %trigger ),
      'GitHub reports the same tree on the approved proposal and its merge';
    ok !admits( \%answers, merged_event() ), 'a dispatch cannot supply a pull request event';
    ok !admits( \%answers, merged_event(), %trigger, GITHUB_SHA => $head ),
      'a different event commit cannot approve the candidate';
    for my $change (
        [ submit      => sub ($e) { $e->{action}                              = 'opened' } ],
        [ repository  => sub ($e) { $e->{repository}{full_name}               = 'fork/Test-Mutation' } ],
        [ merged      => sub ($e) { $e->{pull_request}{merged}                = JSON::PP::false } ],
        [ state       => sub ($e) { $e->{pull_request}{state}                 = 'open' } ],
        [ commit      => sub ($e) { $e->{pull_request}{merge_commit_sha}      = $head } ],
        [ bot         => sub ($e) { $e->{pull_request}{user}{type}            = 'User' } ],
        [ app         => sub ($e) { $e->{pull_request}{user}{id}              = 1 } ],
        [ destination => sub ($e) { $e->{pull_request}{base}{repo}{full_name} = 'fork/Test-Mutation' } ],
        [ fork        => sub ($e) { $e->{pull_request}{head}{repo}{full_name} = 'fork/Test-Mutation' } ],
        [ base        => sub ($e) { $e->{pull_request}{base}{ref}             = 'other' } ],
        [ branch      => sub ($e) { $e->{pull_request}{head}{ref}             = 'ordinary' } ],
      )
    {
        my $e = merged_event();
        $change->[1]->($e);
        ok !admits( \%answers, $e, %trigger ), "different $change->[0] invalidates the release proposal";
    }
    for my $wrong (
        { sha => $source, tree => { sha => $tree } },
        { sha => $head,   tree => { sha => 'a' x 40 } },
        { sha => $head,   tree => {} },
      )
    {
        ok !admits( { %answers, commit($head) => $wrong }, merged_event(), %trigger ),
          'an unrelated commit or tree cannot reuse approval';
    }
    my $failure = { %$pass, state => 'failure' };
    ok !admits( { %answers, statuses($source) => [ [$failure] ] }, merged_event(), %trigger ),
      'a candidate failure overrides a successful proposal';
    ok !admits( { %answers, statuses($head) => [ [] ] }, merged_event(), %trigger ),
      'an untested proposal cannot approve a merge';
    ok !admits( \%answers, merged_event(), %trigger, FAILED_REQUEST => commit($head) ),
      'tree lookup errors fail verification';
};

done_testing;
