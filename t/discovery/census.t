use v5.36;
use Test2::V0;
use File::Temp ();
use List::Util qw(min sum0);
use lib 't/lib', 't/e2e/lib';
use Census;
use Fixture qw(run_fixture write_file);
use Gate;
use Library;
use Oracle;
use Test::Mutation;
use Test::Mutation::Host;

# Every construct that the corpus shows is either mutated or left alone for a stated reason.
# The census reads the files with PPI on its own, so a construct that the analysis of the tool never reports still counts.

sub census_of ($code) {
    return Census::summary(
        [ map { [ 'lib/Sample.pm', $_->@* ] } Census::records( Oracle::text_source( 'lib/Sample.pm', $code ) ) ] );
}

my $tied_handle = <<'CODE';
sub handle { tied($_[0]) and tied($_[0])->can('TIEHANDLE') and return $_[0]; }
CODE

subtest 'a token has the key of its construct' => sub {
    my $code = <<'CODE';
my $x = -$y + 3 - 1;
my %h = ( shift => 1, -bare => 2 );
$o->push( 0x10, 1.5, 1e3, 0b11, 0644 );
if ( $x <=> $#list ) { print "a", 'b', q{c}, qq{d}, qw(e f), <<'EOT' }
text
EOT
elsif ( !$x ) { return +1 }
my $r = $s =~ m/^a+$/i ? qr/b/ : $s =~ s/c/d/r;
$s =~ tr/a/b/;
print -e $path;
CODE
    is [ sort keys census_of($code)->{observed}->%* ],
      [
        sort 'ArrayIndex',
        'HereDoc',
        'Number',
        'Number::Binary',
        'Number::Exp',
        'Number::Float',
        'Number::Hex',
        'Number::Octal',
        'Quote::Double',
        'Quote::Interpolate',
        'Quote::Literal',
        'Quote::Single',
        'QuoteLike::Regexp',
        'QuoteLike::Words',
        'Regexp::Match',
        'Regexp::Substitute',
        'Regexp::Transliterate',
        'Structure',
        'Symbol',
        'Word',
        'operator !',
        'operator + (binary)',
        'operator + (unary)',
        'operator ,',
        'operator - (binary)',
        'operator - (unary)',
        'operator ->',
        'operator -e',
        'operator :',
        'operator <=>',
        'operator =',
        'operator =>',
        'operator =~',
        'operator ?',
        'word elsif',
        'word if',
        'word my',
        'word print',
        'word return',
      ],
      'an operator and a keyword show their text, a sign shows its arity, and a name used as data is a plain word';
};

subtest 'the census rejects a key that no token-level mutant covers' => sub {
    my $census = census_of("sub f { return \$_[0] + \$_[1] <=> 2 }\nsub g { my \$n = 1 + 2; return }\n1;\n");
    is $census->{observed}{'operator + (binary)'}, 2,     'both additions are observed';
    is $census->{claimed}{'operator + (binary)'},  2,     'and a mutator changes each';
    is $census->{observed}{'operator <=>'},        1,     'the comparison of three ways is observed';
    is $census->{claimed}{'operator <=>'},         1,     'and swapping the operands claims the comparison';
    is $census->{claimed}{'Symbol'},               undef, 'a return value that is one variable changes no variable';
    is $census->{claimed}{'Structure'}, undef,
      'and the removal of a statement or of a body changes no token of its own';
    is $census->{claimed}{'word return'}, 1, 'a change of a return value claims the word of its construct';
    is $census->{claimed}{'word sub'},    2, 'and so does the removal of a body';
    is $census->{claimed}{'Number'},      5, 'a number is claimed, in a subscript too';
    is $census->{refused}{'Number'}, 1,
      'and the final value of the file is declined by the rule that refuses its change';
};

subtest 'a change of a wider site claims the tokens that name its construct' => sub {
    my $census = census_of("sub f {\n    if (\$a) { g() } elsif (\$b) { h() }\n    return \$c ? 1 : 2;\n}\n1;\n");
    is [ map { $census->{claimed}{$_} } 'operator ?', 'operator :', 'word elsif', 'word if' ], [ 1, 1, 1, 1 ],
      'the swapped branches claim the question mark and the colon, and the negated condition its keyword';
    is $census->{claimed}{'Word'}, 2, 'and a statement the function that it calls first';
    my $calls = census_of("sub concatenate { join q{}, join q{:}, \@_ }\n1;\n");
    is $calls->{observed}{'word join'}, 2, 'the census observes both calls';
    is $calls->{claimed}{'word join'},  1, 'statement removal claims only the outer call';
    ok !exists Census::declined()->{'word join'}, 'the outer call already has a mutant';
    my $handle = census_of($tied_handle);
    is $handle->{observed}{'word tied'}, 2, 'the handle guard reads the tied object twice';
    is $handle->{claimed}{'word tied'},  1, 'statement removal claims the leading lookup';
    ok !exists Census::declined()->{'word tied'}, 'the guard already has a mutant';
};

subtest 'the gate rejects an undecided key, a declined key with a mutant, and a declined key that never shows' => sub {
    my %census = (
        observed => { 'operator +' => 3, 'operator <=>' => 1, 'operator ,' => 9, 'operator =>' => 2 },
        claimed  => { 'operator +' => 3, 'operator =>'  => 1 },
    );
    my %declined = ( 'operator ,' => 'a separator', 'operator =>' => 'a separator', 'operator ~~' => 'gone from perl' );
    is Census::undecided( \%census, \%declined ),
      [
        'a mutant covers operator =>, and a reason declines it',
        'a reason declines operator ~~, and the corpus never shows it',
        'no mutant covers operator <=>, and no reason declines it',
      ],
      'one finding for each kind of gap';
    is Census::undecided( { observed => { 'operator +' => 1 }, claimed => { 'operator +' => 1 } }, {} ), [],
      'a census without a gap';
    my %refused = ( observed => { 'operator **' => 2 }, claimed => {}, refused => { 'operator **' => 1 } );
    is Census::undecided( \%refused, {} ), [], 'a key whose changes the generator refuses with a rule has its reason';
};

my $account_lookups = <<'CODE';
sub home { (getpwnam $_[0])[7] }
sub uid { scalar getpwnam $_[0] }
CODE

subtest 'account lookups by name return a record or a user ID' => sub {
    my $census = census_of( $account_lookups . 'sub names { my %h = (getpwnam => 1); $obj->getpwnam() }' );
    is $census->{observed}{'word getpwnam'},     2, 'the two calls count under the built-in name';
    is $census->{claimed}{'word getpwnam'} || 0, 0, 'neither lookup has a replacement function';
    like Census::declined()->{'word getpwnam'}, qr/account/, 'the reason identifies the account lookup';
};

subtest 'a range opens an author section and an ellipsis raises an exception' => sub {
    my $source = Oracle::file_source('t/corpus/findings/AuthorSection.pm');
    my $census = census_of( $source->text );
    for my $key ( 'operator ...', 'statement ...' ) {
        is [ $census->{observed}{$key}, $census->{claimed}{$key} ], [ 1, 1 ], "one mutant covers $key";
    }
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$root/lib/AuthorSection.pm", $source->text );
    write_file( "$root/t/authors.t",          <<'TEST' );
use Test::More tests => 2;
use AuthorSection;
is_deeply AuthorSection::authors('before', '=head1 AUTHORS', 'author', '=head1 SEE ALSO', 'after'),
  ['author'], 'the author line lies between the headings';
eval { AuthorSection::unfinished() };
like $@, qr/Unimplemented/, 'an unfinished section raises the Perl exception';
TEST
    my @changes = grep {
             ( $_->mutator eq 'range-boundary' && $_->original eq '...' )
          || ( $_->mutator eq 'statement-removal' && $_->original eq '...;' )
    } Test::Mutation::mutants( root => $root, profile => 'extended' )->@*;
    is scalar @changes, 2, 'the range endpoint and the unimplemented statement have distinct mutants' or return;
    my ($result) =
      run_fixture( $root, cache => 0, jobs => 1, profile => 'extended', mutant => [ map { $_->id } @changes ] );
    is $result->baseline_failures, [], 'the original returns the author and throws for the unfinished section';
    is [ map { [ $_->@{qw(status by)} ] } $result->entries->@* ],
      [ [ 'Killed', 't/authors.t' ], [ 'Killed', 't/authors.t' ] ],
      'tests detect ending the section immediately and omitting the exception';
};

subtest 'the parent process ID is measured in statement and value contexts' => sub {
    my $source = Oracle::file_source('t/corpus/findings/ParentProcess.pm');
    my $census = census_of( $source->text );
    is $census->{observed}{'word getppid'}, 2, 'both parent lookups appear in the corpus';
    is $census->{claimed}{'word getppid'},  1, 'only the lookup at the head of its statement is claimed';
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$root/lib/ParentProcess.pm", $source->text );
    write_file( "$root/t/parent.t",           <<'TEST' );
use Test::More tests => 1;
use ParentProcess;
is ParentProcess::parent_pid(), getppid(), 'the parent PID is returned';
TEST
    write_file( "$root/t/profile.t", <<'TEST' );
use Test::More tests => 2;
use ParentProcess;
is ParentProcess::profile_pid($$), $$, 'the initial process uses its own PID';
is ParentProcess::profile_pid(getppid()), getppid(), 'a child uses its parent PID';
TEST
    my @mutants = Test::Mutation::mutants( root => $root )->@*;
    my ($remove) = grep { $_->mutator eq 'statement-removal' && $_->original eq 'getppid()' } @mutants;
    ok $remove, 'the generator removes the implicit return' or return;
    is $remove->replacement, q{}, 'the empty body returns undef in scalar context';
    my ($swap) = grep { $_->mutator eq 'condition-negation' } @mutants;
    ok $swap, 'the generator swaps the profile PID branches' or return;
    is $swap->replacement, 'getppid() : $$', 'both swapped branches still produce a PID';
    my ($result) = run_fixture( $root, cache => 0, jobs => 1, equivalence => 0, mutant => [ $remove->id, $swap->id ] );
    is $result->baseline_failures, [], 'the project first returns the expected process IDs';
    my %detections = map { $_->{mutant}->mutator => [ $_->@{qw(status by)} ] } $result->entries->@*;
    is \%detections,
      { 'statement-removal' => [ 'Killed', 't/parent.t' ], 'condition-negation' => [ 'Killed', 't/profile.t' ] },
      'the tests detect a missing PID and a PID from the wrong process';
};

subtest 'a statement that no mutant touches counts for its class' => sub {
    my $census = census_of("use strict;\nmy \$n = 3;\nmy \@list;\nsub f { return 1 + 2 }\n1;\n");
    is $census->{statements},
      {
        'Statement'           => { all => 1, bare => 0, refused => 1 },
        'Statement::Break'    => { all => 1, bare => 0, refused => 0 },
        'Statement::Include'  => { all => 1, bare => 1, refused => 0 },
        'Statement::Variable' => { all => 2, bare => 1, refused => 0 },
      },
      'the statements by class: with a mutant, with every change refused under a rule, or with no change at all';
    is Census::bare_classes($census), ['Statement::Include'], 'a class whose statements all go without a change';
    is $census->{refused}{'Number'},  1, 'the final value of the file is a number that the generator declines';
};

subtest 'the census rejects a pattern that the analysis leaves out without a count' => sub {
    my $code = "use constant PATTERN => qr/b/;\nuse Metadata qr/unread/;\nuse Hook sub { qr/c/ };\n"
      . "sub f { return \$_[0] =~ /^a+\$/ }\n1;\n";
    my $sound = census_of($code);
    is [ $sound->@{qw(dropped unparsed patterns)} ], [ 0, 0, 3 ],
      'the constant, callback, and return value hold patterns that the parser reads';
    my $failing = do {
        no warnings 'redefine';
        local *PPIx::Regexp::failures = sub { return 1 };
        census_of($code);
    };
    is [ $failing->@{qw(dropped unparsed patterns)} ], [ 3, 3, 3 ],
      'the analysis counts the pattern that PPIx::Regexp fails on, as the census does';
    is Census::uncounted($failing), [], 'so the two counts agree';
    my $split = Census::summary( [ [ 'lib/A.pm', 'dropped', 1, 0, 1 ], [ 'lib/B.pm', 'dropped', 0, 1, 1 ] ] );
    is Census::uncounted($split),
      ['the analysis leaves out a pattern that PPIx::Regexp cannot read, without a count'],
      'a file with a pattern left out in silence fails, though another file counts one pattern more';
    is Census::uncounted( { dropped => 2, unparsed => 2 } ), [], 'the analysis counts each pattern that it leaves out';
    is Census::uncounted( { dropped => 1, unparsed => 3 } ),
      ['the analysis leaves out a pattern that PPIx::Regexp cannot read, without a count'],
      'a pattern without a count is a finding';
};

# The seed shows each declined construct that the corpus lacks, in a declaration that no mutator changes.
my $SEED = $account_lookups . $tied_handle . <<'CODE';
my ( $x, @list ) = ( \&code, [ 1, 2 ] );
print { $x->[0] } "@list$#list";
LABEL: for my $item ( @{ $x }, $_ ) { next LABEL }
sub with($) { return }
sub attributed :lvalue { $x }
my @records = glob '*.rec';
my $epoch = sub { time };
my $encode = sub { pack 'H*', $_[0] };
my $order = $x cmp 'limit';
my @declined = ( 0b11, 1e3, +$x, `true`, qx{true}, getpgrp($x), chown( 0, 0, $x ), ioctl( $x, 0, $x ), each %$x, gethostbyname $x );
my @valued = ( gmtime $x, localtime $x, log $x, lstat $x, ord $x, prototype $x, tell $x, telldir $x, tied $x, fc $x );
foreach my $item (@list) { } continue { }
sub counted { state $count; goto &code }
__END__
CODE

my @files   = map { Library::modules($_)->@* } 't/corpus', 't/fixtures', 'lib';
my $workers = min( 8, Test::Mutation::Host::processors()->{count} );
my $records =
  Oracle::each_file( \@files, $workers, sub ($path) { return Census::records( Oracle::file_source($path) ) } );
push $records->@*, map { [ 'seed', $_->@* ] } Census::records( Oracle::text_source( 'seed', $SEED ) );
my $census = Census::summary($records);

note sprintf '%-28s %8s %8s', 'key', 'observed', 'claimed';
note sprintf '%-28s %8d %8d', $_, $census->{observed}{$_}, $census->{claimed}{$_} || 0
  for sort keys $census->{observed}->%*;
note sprintf '%-28s %6d statements, %6d without a change, %6d with every change refused', $_,
  $census->{statements}{$_}->@{qw(all bare refused)}
  for sort keys $census->{statements}->%*;
note sprintf '%s: %d of %d statements without a change', $_->@* for Census::barest_files( $census, 10 );
note
  "PPIx::Regexp read $census->{patterns} patterns and fails on $census->{unparsed}, and the analysis counts $census->{dropped} as left out";

is $census->{unplaced}, 0, 'PPI places every token of the corpus on its own text';
Gate::findings( 'mutants-dropped-corpus', Census::uncounted($census) );
is Census::undecided( $census, Census::declined() ), [],
  'every construct of the corpus has a mutant or a reason in the declined table, and every reason stands alone';
Gate::findings( 'mutants-statements-corpus',
    [ map { "no mutant touches a statement of the class $_" } Census::bare_classes($census)->@* ] );
Gate::checked( 'files',      scalar @files,                                              at_least => 50 );
Gate::checked( 'keys',       scalar keys $census->{observed}->%*,                        at_least => 80 );
Gate::checked( 'tokens',     sum0( values $census->{observed}->%* ),                     at_least => 30_000 );
Gate::checked( 'statements', sum0( map { $_->{all} } values $census->{statements}->%* ), at_least => 4000 );
Gate::checked( 'patterns that PPIx::Regexp read', $census->{patterns},                   at_least => 90 );

done_testing;
