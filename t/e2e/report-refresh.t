use v5.36;
use Test2::V0;
use File::Copy       ();
use File::Temp       ();
use IO::Socket::UNIX ();
use POSIX            ();
use Socket           ();
use Test::Mutation::Report::Json;
use lib 't/e2e/lib';
use Fixture qw(ran write_file);

my $project = File::Temp::tempdir( CLEANUP => 1 );
write_file( "$project/lib/Totals.pm", 'package Totals; sub sum { return $_[0] + $_[1] } 1;' );
write_file( "$project/t/value.t",     "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 0), 4;\n" );
my @options = ( '--format', 'json', '--format', 'html', '--jobs', 1 );
my $files   = "$project/mutation-report";

sub report ( $format, $path = "$files/mutation.$format" ) {
    open my $file, '<:encoding(UTF-8)', $path or die $!;
    my $text = do { local $/ = undef; readline $file };
    close $file or die $!;
    if ( $format eq 'html' ) {
        ($text) = $text =~ m{<script id="report" type="application/json">(.+?)</script>}s;
    }
    return Test::Mutation::Report::Json::parse($text);
}

ran( 0, $project, @options );
my $whole = report('json');
my %first = map { $_->{mutant}->id => $_->{status} } $whole->entries->@*;
my ($id)  = grep { $first{$_} eq 'Survived' } sort keys %first;
ok defined $id, 'the original suite misses a change';
subtest 'inspection uses the older valid report when the newer file is incomplete' => sub {
    my $history = File::Temp::tempdir( CLEANUP => 1 );
    for my $case ( [ json => 'html', q{} ], [ json => 'html', '{"files":' ], [ html => 'json', '<html></html>' ], ) {
        my ( $newer, $older, $broken ) = @$case;
        my $valid = "$history/mutation.$older";
        File::Copy::copy( "$files/mutation.$older", $valid ) or die "copy the older report: $!";
        utime 1, 1, $valid or die "date the older report: $!";
        write_file( "$history/mutation.$newer", $broken );
        my $shown = ran( 0, $project, 'show', $id, '--no-cache', '--report-dir', $history );
        like $shown->{stdout}, qr/^Last result: Survived$/m, "the older $older report supplies the result";
    }
};
subtest 'inspection skips a socket at the newer report path' => sub {
    my $history = File::Temp::tempdir( DIR => '/tmp', CLEANUP => 1 );
    my $older   = "$history/mutation.html";
    File::Copy::copy( "$files/mutation.html", $older ) or die "copy the HTML report: $!";
    utime 1, 1, $older or die "date the HTML report: $!";
    my $path   = "$history/mutation.json";
    my $socket = IO::Socket::UNIX->new( Type => Socket::SOCK_STREAM(), Local => $path, Listen => 1 )
      or die "listen at the other report path: $!";
    my $shown = ran( 0, $project, 'show', $id, '--no-cache', '--report-dir', $history );
    like $shown->{stdout}, qr/^Last result: Survived$/m, 'the regular HTML file supplies the verdict';
    ok -S $path, 'inspection preserves the live socket';
};
write_file( "$project/t/stronger.t", "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 1), 5;\n" );
ran( 0, $project, @options, '--mutant', $id );
for my $format (qw(json html)) {
    my $saved = report($format);
    is {
        map { $_->{mutant}->id => $_->{status} } $saved->entries->@*
    }, { $id => 'Killed' }, "the $format report scores only the named mutant";
    is $saved->tally->{score},       100,   "the stronger test gives the selected $format measurement a full score";
    is $saved->selection->{mutants}, [$id], 'the most recent selection survives serialization';
}

unlink "$files/mutation.json" or die $!;
ran( 0, $project, '--format', 'html', '--jobs', 1, 'lib/Totals.pm:1' );
is scalar report('html')->entries->@*, scalar keys %first, 'an HTML-only update preserves the matching report';
write_file( "$project/lib/Other.pm", 'package Other; sub product { return $_[0] * 2 } 1;' );
ran( 0, $project, @options, '--mutant', $id );
is [ map { $_->{mutant}->id } report('json')->entries->@* ], [$id],
  'a changed source inventory starts a separate report';

my $link = "$files/mutation.json";
unlink $link or die $!;
my $published = "$project/published.json";
write_file( $published, "previous publication\n" );
chmod oct('640'), $published or die "set report permissions: $!";
symlink '../published.json', $link or die "link the report: $!";
ran( 0, $project, '--format', 'json', '--jobs', 1, '--mutant', $id );
is readlink($link), '../published.json', 'publishing through a relative symlink preserves the link';
is( ( stat $published )[2] & oct('777'), oct('640'), 'the published file retains the existing access permissions' );
is [ map { $_->{mutant}->id } report( 'json', $published )->entries->@* ], [$id],
  'the symlink target receives the completed measurement';

unlink $link or die $!;
symlink $project, $link or die $!;
my $rejected = ran( 5, $project, '--format', 'json', '--jobs', 1 );
like $rejected->{stderr}, qr/cannot write .*mutation[.]json/, 'the diagnostic names the report linked to a directory';
ok -l $link && -d $project, 'a non-file report destination retains its identity';

unlink $link                      or die $!;
POSIX::mkfifo( $link, oct '600' ) or die $!;
ran( 5, $project, '--format', 'json', '--jobs', 1 );
ok -p $link, 'a named pipe is never replaced by a regular report';

done_testing;
