use strict;
use warnings;
use Cwd        ();
use File::Spec ();
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(project write_file);

my ( $start, $root, $input, $record, $setting );

BEGIN {
    $start  = Cwd::getcwd();
    $root   = project();
    $input  = write_file( "$root/setting", '3' );
    $record = "$root/records/observed";
    write_file( "$root/WorkingLibrary.pm", "package WorkingLibrary; sub value { return 4 } 1;\n" );
    local $ENV{TEST_MUTATION_COMPILER_INPUTS} = $record;
    local $ENV{TEST_MUTATION_COMPILER_READS}  = 'f' . unpack( 'H*', $input );
    unshift @INC, q{.};
    require Test::Mutation::CompilerInputs;
    chdir $root or die "enter compiler project: $!";
    require WorkingLibrary;
    open my $configuration, '<', $input or die "read compiler setting: $!";
    $setting = <$configuration>;
    close $configuration or die "close compiler setting: $!";
}

chdir $start or die "leave compiler project: $!";
is WorkingLibrary::value() + $setting, 7, 'the compiler used the new module and the original setting';
open my $in, '<', $record or die "read compiler record: $!";
chomp( my @lines = <$in> );
close $in or die "close compiler record: $!";
is pop(@lines), q{.}, 'the compiler completed the record after the directory change';
my %seen = map { $_ => 1 } @lines;
ok $seen{ unpack 'H*', $root }, 'the original dot entry now identifies the new directory';
ok !$seen{ unpack 'H*', $start }, 'the initial directory is already part of the compiler inputs';
ok $seen{ unpack 'H*', $input }, 'an absolute file operand still identifies the same setting';
my %module = map { File::Spec->canonpath( pack 'H*', substr $_, 1 ) => 1 } grep { /\Am/ } @lines;
ok $module{"$root/WorkingLibrary.pm"}, 'the module loaded in the new directory has its own source record';

done_testing;
