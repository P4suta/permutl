use v5.36;
use Test2::V0;
use File::Temp  ();
use POSIX       ();
use Time::HiRes ();
use lib 't/e2e/lib';
use Fixture qw(write_file);
use Test::Mutation;
use Test::Mutation::Select;
use Test::Mutation::Settings;
use Test::Mutation::Store;

my $control = File::Temp::tempdir( CLEANUP => 1 );
my $project = "$control/project";
local $ENV{MUTATION_CHECKPOINT_TEST} = $control;
for my $name (qw(Quiet Noisy)) {
    write_file( "$project/lib/$name.pm", "package $name;\n" . 'sub sum { return $_[0] + $_[1] }' . "\n1;\n" );
}
write_file( "$project/t/quiet.t", <<'TEST' );
use Test::More tests => 1;
use Quiet;
my $sum = Quiet::sum(7, 2);
my $started = "$ENV{MUTATION_CHECKPOINT_TEST}/quiet-started";
if ($sum != 9 && !-d $started) { mkdir $started or die "mark the running mutant: $!" }
is $sum, 9;
TEST
write_file( "$project/t/noisy.t", <<'TEST' );
use strict;
use warnings;
use Test::More tests => 1;
use Noisy;
my $control = $ENV{MUTATION_CHECKPOINT_TEST};
my $sum = Noisy::sum(7, 2);
if ($sum != 9 && !-e "$control/drained") {
    select undef, undef, undef, 0.01 until -e "$control/locked";
    print STDERR 'x' x 2_000_000 or die "write diagnostics: $!";
    open my $done, '>', "$control/drained" or die "mark drained: $!";
    close $done or die "close marker: $!";
}
is $sum, 9;
TEST

my $config   = Test::Mutation::Settings::of_call( { root => $project } );
my $selected = Test::Mutation::Select::resolve( config => $config, read_only => 1 );
my @ids      = map { $_->id } grep { $_->mutator eq 'arithmetic' } $selected->mutants->@*;
is scalar @ids, 2, 'each test exercises one selected addition';

sub hold_until_drained ($path) {
    pipe my $ready, my $notify or die "pipe: $!";
    my $child = fork;
    die "fork: $!" unless defined $child;
    if ( !$child ) {
        close $ready or die "close lock reader: $!";
        my $db = Test::Mutation::Store::database($path);
        $db->do('BEGIN IMMEDIATE');
        write_file( "$control/locked", 'ready' );
        syswrite $notify, 'x' or die "announce lock: $!";
        close $notify or die "close lock writer: $!";
        my $until = Time::HiRes::time() + 3;
        Time::HiRes::sleep(0.01) while !-e "$control/drained" && Time::HiRes::time() < $until;
        my $drained = -e "$control/drained";
        $db->do('COMMIT');
        POSIX::_exit( $drained ? 0 : 73 );
    }
    close $notify                          or die "close lock writer: $!";
    sysread( $ready, my $acknowledged, 1 ) or die "wait for write lock: $!";
    close $ready                           or die "close lock reader: $!";
    return $child;
}

my ( $locker, @published );
my $checkpoints = Test::Mutation::Store->can('checkpoints');
my $result;
{
    no warnings 'redefine';
    local *Test::Mutation::Store::checkpoints = sub ($path) {
        ok !-d "$control/quiet-started", 'the writer opens before live mutant tests can need supervision';
        my $write = $checkpoints->($path);
        return sub (@arguments) {
            $locker ||= hold_until_drained($path);
            return $write->(@arguments);
        };
    };
    $result = Test::Mutation::run(
        root          => $project,
        jobs          => 2,
        mutant        => \@ids,
        timeout_floor => 12,
        on_event      => sub ( $event, $entry ) {
            return unless $event eq 'mutant';
            my $db = Test::Mutation::Store::database( Test::Mutation::Store::path( $config, 0 ) );
            push @published, $db->selectrow_array( 'SELECT id FROM verdict WHERE id = ?', undef, $entry->{mutant}->id );
            return;
        }
    );
}
waitpid $locker, 0;
is $? >> 8,             0,             'the other test drains its diagnostics while a SQLite write lock is held';
is [ sort @published ], [ sort @ids ], 'each completion is published after its durable checkpoint';
is [ map { $_->{status} } $result->entries->@* ], [qw(Killed Killed)], 'both tests retain their observed verdicts';
subtest 'an interrupt commits a completed test before reporting its unfinished peer' => sub {
    unlink "$control/locked", "$control/drained" or die "reset checkpoint gates: $!";
    my $path = Test::Mutation::Store::path( $config, 0 );
    my $db   = Test::Mutation::Store::database($path);
    $db->do('DELETE FROM verdict');
    my ( $completed, @notified );
    no warnings 'redefine';
    local *Test::Mutation::Store::checkpoints = sub ($path) {
        my $write = $checkpoints->($path);
        return sub ( $id, $record, $may_wait ) {
            unless ( defined $completed ) {
                $completed = $id;
                ok !$may_wait, 'the other test is still running';
                kill 'TERM', $$;
                return 0;
            }
            return $write->( $id, $record, $may_wait );
        };
    };
    my $interrupted = Test::Mutation::run(
        root          => $project,
        jobs          => 2,
        mutant        => \@ids,
        timeout_floor => 12,
        on_event      => sub ( $event, $entry ) { push @notified, $entry->{mutant}->id if $event eq 'mutant'; return }
    );
    is $interrupted->interrupted, 'TERM', 'the measurement reports the signal';
    is [ sort map { $_->{status} } $interrupted->entries->@* ], [qw(Killed Pending)],
      'only the unfinished peer stays pending';
    is $db->selectcol_arrayref('SELECT id FROM verdict'), [$completed],
      'a resumed process can read the completed verdict';
    is \@notified, [$completed], 'the committed result is published once';
};
done_testing;
