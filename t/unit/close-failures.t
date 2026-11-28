use v5.36;
use Test2::V0;
use File::Temp ();

# A close that fails means lost data or an unread error, so the library checks every close.
# The override below closes the handle and then reports a failure to the subroutine that the pattern names.
our $failing;    ## no critic (Variables::ProhibitPackageVars)
my $fail_directory_close;

BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::close = sub : prototype(;*) (@handle) {
        my $closed = @handle ? CORE::close( $handle[0] ) : CORE::close();
        my $caller = ( caller 1 )[3] || 'main';
        return $closed if !defined $failing || $caller !~ $failing;
        $! = 5;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return !1;
    };
    *CORE::GLOBAL::closedir = sub : prototype(*) ($handle) {
        my $closed = CORE::closedir($handle);
        return $closed unless $fail_directory_close;
        $! = 5;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return !1;
    };
}

use lib 'xt/lib';
use SelfMeasurement;
use Test::Mutation::Store;
use Test::Mutation::Store::Key;
use Test::Mutation::Settings;
use Test::Mutation::Host;
use Test::Mutation::Project;
use Test::Mutation::Tree;
use Test::Mutation::Workspace::Slot;
use Test::Mutation::Source;
use Test::Mutation::Record;
use Test::Mutation::Report::Html;
use Test::Mutation::Report::Publication;

my $directory = File::Temp::tempdir( CLEANUP => 1 );

sub write_file ( $name, $text ) {
    open my $handle, '>', "$directory/$name" or die "write $name: $!";
    print {$handle} $text or die "write $name: $!";
    CORE::close($handle)  or die "close $name: $!";
    return "$directory/$name";
}

sub failing_in ( $pattern, $code ) {
    local $failing = $pattern;
    return $code->();
}

my $recent = write_file( 'recent', 'contents whose digest is required' );
like dies {
    failing_in( qr/::Tree::_signature\z/, sub { Test::Mutation::Tree::snapshot( root => $directory, skip => [] ) } )
}, qr/cannot close \Q$recent\E/, 'a failed close invalidates the measured file signature';

like dies {
    failing_in( qr/::Key::file\z/, sub { Test::Mutation::Store::Key::file($recent) } )
}, qr/\Acannot close \Q$recent\E: /, 'a file that failed to close cannot supply a cache key';
$fail_directory_close = 1;
like dies { Test::Mutation::Store::Key::tree( $directory, [] ) }, qr/\Acannot close \Q$directory\E: /,
  'a directory that failed to close cannot supply a project key';
$fail_directory_close = 0;

my $command = write_file( 'tool', "#!perl\n1;\n" );
like dies {
    failing_in( qr/::Project::perl_script\z/, sub { Test::Mutation::Project::perl_script($command) } )
}, qr/\Acannot close \Q$command\E: /, 'script selection refuses a prefix whose handle failed to close';

my $record = {
    inputs    => 'k',
    status    => 'Killed',
    reason    => undef,
    detail    => undef,
    by        => 't/a.t',
    tests_run => 1,
    duration  => 0.1,
    code      => undef
};
my $cache = "$directory/cache.json";
is Test::Mutation::Store::save( $cache, { abc => $record } ), 1,       'the cache is written';
is [ keys Test::Mutation::Store::load($cache)->%* ],          ['abc'], 'and read back';
is failing_in( qr/::Store::_read\z/, sub { Test::Mutation::Store::load($cache) } ), {},
  'a cache that does not close counts as no cache';
like dies {
    failing_in( qr/::Store::_merge_records\z/, sub { Test::Mutation::Store::save( $cache, { abc => $record } ) } )
}, qr/\Acannot close \Q$cache\E[.]\d+: /, 'a cache that does not close after the write stops the run';

like dies {
    failing_in( qr/::Store::save\z/, sub { Test::Mutation::Store::save( $cache, { abc => $record } ) } )
}, qr/\Acannot close \Q$cache.lock\E: /, 'a failed close of the cache writer lock is reported to the caller';

write_file( 'mutation.toml', "jobs = 2\n" );
my %plain = (
    root  => $directory,
    given => { origin     => 'line', name => undef, entries => {} },
    facts => { processors => 1, env => {} }
);
is Test::Mutation::Settings::configure(%plain)->jobs, 2, 'the configuration file is read';
like dies {
    failing_in( qr/::Settings::_file_layer\z/, sub { Test::Mutation::Settings::configure(%plain) } )
}, qr/\Acannot close mutation[.]toml: /, 'a configuration file that does not close is an error';

my $records = write_file( 'one.rec', "begin\t0\naround\t/p/A.pm\n" );
is Test::Mutation::Record::read_directory($directory)->{bypassed}, { '/p/A.pm' => 1 }, 'the record file is read';
like dies {
    failing_in( qr/::Record::read_directory\z/, sub { Test::Mutation::Record::read_directory($directory) } )
}, qr/\Acannot close \Q$records\E: /, 'a record file that does not close is an error';
$fail_directory_close = 1;
like dies { Test::Mutation::Record::read_directory($directory) }, qr/\Acannot close \Q$directory\E: /,
  'a record directory that does not close is an error';
$fail_directory_close = 0;

is failing_in( qr/::Host::_read\z/, sub { Test::Mutation::Host::processors() } ), { count => 1, source => 'none' },
  'a processor count that does not close counts as no answer';

ok length Test::Mutation::Report::Html::viewer_script(), 'the viewer script is read';
like dies {
    failing_in( qr/::Html::viewer_script\z/, sub { Test::Mutation::Report::Html::viewer_script() } )
}, qr/\Acannot close \S+mutation-test-elements[.]js: /, 'a viewer script that does not close is an error';

my $published = { 'mutation.json' => 'b' x 64 };
like dies {
    failing_in( qr/::Publication::record\z/,
        sub { Test::Mutation::Report::Publication::record( $directory, $directory, $published ) } )
}, qr/\Acannot close .*\.test-mutation-outputs: /, 'a failed close prevents successful publication';
Test::Mutation::Report::Publication::record( $directory, $directory, $published );
like dies {
    failing_in( qr/::Publication::outputs\z/, sub { Test::Mutation::Report::Publication::outputs( $directory, q{.} ) } )
}, qr/\Acannot close .*\.test-mutation-outputs: /, 'a read handle that fails to close cannot identify published files';

my $target = write_file( 'slot-source.pm', "1;\n" );
like dies {
    failing_in(
        qr/::Slot::_replace\z/,
        sub {
            Test::Mutation::Workspace::Slot::place( $directory, 'slot-source.pm', "1;\n", "2;\n" );
        }
    )
}, qr/\Acannot close \Q$target\E: /, 'a failed close refuses to install incomplete bytes';
is Test::Mutation::Source::read_bytes($target), "1;\n", 'a failed staging-file close keeps the source unchanged';

my $report = write_file( 'unclosed-report.json', '{}' );
like dies {
    failing_in( qr/\ASelfMeasurement::read_report\z/, sub { SelfMeasurement::read_report($report) } )
}, qr/\Aclose \Q$report\E: /, 'the release refuses a saved report whose read handle failed to close';

done_testing;
