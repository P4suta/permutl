use v5.36;
use Test2::V0;
use lib 't/lib', 't/shim/lib';
use Capability;
use ShimHarness qw(project run_command write_file);
use Test::Mutation::Syntax::PPI;

my $module_start = <<'PERL';
use experimental 'class';
sub read_limit {
    open my $table, '<', $ENV{CLASS_TABLE} or die $!;
    print scalar <$table>;
    close $table or die $!;
    return 3;
}
PERL

my @declarations = (
    q{class First { method count { 1 } } class Second 1.0 { method count { 2 } } 1;},
    q{class Meter {}; 1;},
    q{class x v1.2.3 { method answer { 42 } } 1;},
);
my @readers = (
    q{class First {} class Second { my $limit = main::read_limit(); } 1;},
    q{class Meter {} read_limit; 1;},
    q{class Meter {} 0 + read_limit(); 1;},
    q{class Meter; main::read_limit(); 1;},
    q{sub Rules::apply { return main::read_limit() } apply Rules {}; 1;},
    q{class Derived :isa(Local::Parent 1.0) {} 1;},
    q{class Meter 1.0 { main::read_limit(); } 1;},
);

subtest 'classes can share a module with other declarations and load-time expressions' => sub {
    my $reads = sub ($body) { return scalar Test::Mutation::Syntax::PPI::compile_reads( "$module_start$body", 1 ) };
    is $reads->($_), [], "the declarations have no load-time input in $_" for @declarations;
    for my $body (@readers) {
        is $reads->($body), undef, "loading the module can execute read_limit in $body";
    }
    is $reads->(q{class Derived 1.0 :isa(Local::Parent) {} 1;}), undef,
      'a versioned subclass can load an external parent';
    is $reads->(q{class Meter 1.0 unfinished; 1;}), undef, 'an incomplete class header supplies no proof of its inputs';
};

subtest 'requiring each native class module observes its expected file reads' => sub {
    my $has_class = $] >= 5.038;
    return unless Capability::has( 'class', $has_class, 'native classes need Perl 5.38' );
    my $root  = project();
    my $table = write_file( "$root/limit", "42\n" );
    write_file( "$root/Local/Parent.pm",
        "use experimental 'class'; class Local::Parent 1.0 {} main::read_limit(); 1;\n" );
    for my $case ( ( map { [ $_, q{} ] } @declarations ), ( map { [ $_, "42\n" ] } @readers ) ) {
        my ( $body, $output ) = @$case;
        write_file( "$root/Measured.pm", "$module_start$body\n" );
        my $result = run_command(
            root    => $root,
            command => [ $^X, "-I$root", '-MMeasured', '-e', '1' ],
            env     => { CLASS_TABLE => $table }
        );
        is $result, { status => 0, signal => 0, stdout => $output, stderr => q{} }, "loading $body";
    }
};

subtest 'native object initialization is deferred while a class body can run code at load' => sub {
    my $pragma = q{use experimental 'class';};
    my $reads  = sub ($source) { return scalar Test::Mutation::Syntax::PPI::compile_reads( "$pragma $source", 1 ) };
    is $reads->(
        q{class Model 1.0 { field $n :param = read_setting(); ADJUST { observe() } method get { return $n } } 1;}),
      [], 'loading declarations does not initialize a field, adjust an object, or call a method';
    is $reads->(q{class Model { method get { 1 } read_setting(); } 1;}), undef,
      'a call following a method runs as part of the class body';
    is $reads->(q{class Model { method get { 1 } } read_setting(); 1;}), undef,
      'a call following the class runs as part of the file';
    is $reads->(q{class Model { method get { 1 } }; open my $data, '<', $ENV{CLASS_FILE} or die $!; 1;}), undef,
      'loading the module opens the file named in a separate statement after the class';
    is $reads->(q{class Model { method get { 1 } BEGIN { read_setting() } } 1;}), undef,
      'a phase block after a method can read a file while compiling the class';
    is $reads->(q{class Model { method get { method inner { 1 } BEGIN { read_setting() } } } 1;}), undef,
      'a phase block inside a nested declaration runs before any method is called';
    is $reads->(q{class Model :isa(External) { method get { 1 } } 1;}), undef,
      'the base class can require an external module';
    is $reads->(q{class Model { method import { read_setting() } } 1;}), undef, 'an import method can run on use';
};

done_testing;
