package Test::Mutation::CLI;
use v5.36;
use Cwd            ();
use Errno          ();
use File::Spec     ();
use File::Basename ();
use File::Temp     ();
use Fcntl          qw(O_RDONLY LOCK_EX SEEK_END S_ISREG);
use List::Util     ();
use Scalar::Util   ();
use Time::HiRes    ();
use IO::File       ();
use IO::Handle     ();
use Types::Standard
  qw(ArrayRef Bool CodeRef Dict Enum FileHandle GlobRef HashRef InstanceOf Int Maybe Optional Slurpy Str);
use Types::Common::Numeric qw(PositiveInt);
use Type::Params           qw(signature_for);
use overload               ();
use Test::Mutation::CLI::Arguments;
use Test::Mutation::Commands;
use Test::Mutation::Config;
use Test::Mutation::Error;
use Test::Mutation::Exit;
use Test::Mutation::Host;
use Test::Mutation::Interrupted;
use Test::Mutation::Outcome;
use Test::Mutation::Message;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Report::Patch;
use Test::Mutation::Report::Results;
use Test::Mutation::Report::Live;
use Test::Mutation::Report::Terminal;
use Test::Mutation::Store::History;
use Test::Mutation::Select;
use Test::Mutation::Settings;
use Test::Mutation::Types qw(PathSelection);
use POSIX                 ();
use Test::Mutation::Signals;
use Test::Mutation::Tree;
use Test::Mutation::Try;

our $VERSION = '0.001';

my $TYPED        = InstanceOf ['Test::Mutation::Error'];
my $INTERRUPTION = InstanceOf ['Test::Mutation::Interrupted'];

# The command that mutation exec runs owns every other status, so exec reports its own failures with the statuses of env.
# A command that exists nowhere or that the system refuses to run has a status of its own, and every other failure has 125.
my %OF_EXEC_COMMAND = ( 'command-not-found' => 'command-not-found', 'command-not-runnable' => 'command-not-runnable' );
my %IN_EXEC         = ( environment         => 'exec-failed',       internal               => 'exec-failed' );

my %COMMAND = (
    run      => \&_run,
    baseline => \&_baseline,
    settings => \&_settings,
    list     => \&_list,
    show     => \&_show,
    exec     => \&_exec,
    merge    => \&_merge,
    mutators => \&_mutators
);

signature_for main => ( positional => [ Slurpy [ ArrayRef [Str] ] ], returns => Int );
signature_for main_with_detector_hints => (
    positional => [ HashRef [Str], Slurpy [ ArrayRef [Str] ] ],
    returns    => Int,
);

# A standard stream of the process may be closed, and the command still ends with a status.
my $STREAM = FileHandle | GlobRef;

# The facts that the command reads from its process, so that a caller may give other ones.
my $WORLD = Dict [
    cwd            => Maybe [Str],
    env            => HashRef [ Maybe [Str] ],
    out            => $STREAM,
    err            => $STREAM,
    out_tty        => Bool,
    err_tty        => Bool,
    clock          => CodeRef,
    processors     => CodeRef,
    detector_hints => Optional [ HashRef [Str] ],
];
my $REFUSED    = Dict [ refused => Dict [ status => Int, text => Str ] ];
my $INVOCATION = $REFUSED | Dict [
    command    => Enum [ ( map { $_->name } Test::Mutation::Commands::rows()->@* ), 'version' ],
    directory  => Maybe [Str],
    config     => Maybe [ InstanceOf ['Test::Mutation::Config'] ],
    operands   => ArrayRef [Str],
    selection  => Optional [ InstanceOf ['Test::Mutation::Selection'] ],
    paths      => Optional [PathSelection],
    topic      => Optional [Str],
    processors => Maybe [ Dict [ count => PositiveInt, source => Str ] ],
];

# The words of an option in the help text: its spellings and the placeholder of its value.
sub _option_words ($setting) {
    my @spelled = (
        $setting->flag,
        ( defined $setting->short  ? $setting->short          : () ),
        ( $setting->kind eq 'flag' ? '--no-' . $setting->name : () ),
    );
    return join q{ }, join( q{, }, @spelled ), ( defined $setting->placeholder ? $setting->placeholder : () );
}

sub _help ($command) {
    my @commands = Test::Mutation::Commands::rows()->@*;
    my @rows     = $command ? ($command) : @commands;
    my $text     = 'Usage: ' . join( "\n       ", map { $_->usage } @rows ) . "\n";
    if ( !$command ) {
        my $width = List::Util::max( map { length $_->name } @commands );
        $text .= "\nCommands:\n" . join q{}, map { sprintf "  %-*s  %s\n", $width, $_->name, $_->summary } @commands;
    }
    my @options = map { [ _option_words($_), $_->help ] }
      grep { $_->offers('line') && ( !$command || $command->accepts( $_->name ) ) }
      Test::Mutation::Settings::rows()->@*;
    push @options, map { [ join( q{, }, $_->{words}->@* ), $_->{summary} ] } Test::Mutation::Commands::switches()->@*;
    my $width = List::Util::max( map { length $_->[0] } @options );
    return $text . "\nOptions:\n" . join q{}, map { sprintf "  %-*s  %s\n", $width, $_->@* } @options;
}

sub main ($list) {
    return main_with_detector_hints( {}, @$list );
}

sub main_with_detector_hints ( $hints, $list ) {
    for my $stream ( \*STDOUT, \*STDERR ) {
        next unless defined fileno $stream;
        binmode $stream, ':raw:encoding(UTF-8)'
          or Test::Mutation::Error::raise( 'file-unwritable', path => "$stream", reason => "$!" );
        $stream->autoflush(1);
    }
    my $world = {
        cwd        => Cwd::getcwd(),
        env        => \%ENV,
        out        => \*STDOUT,
        err        => \*STDERR,
        out_tty    => _terminal( \*STDOUT ),
        err_tty    => _terminal( \*STDERR ),
        clock      => sub { Time::HiRes::clock_gettime( Time::HiRes::CLOCK_MONOTONIC() ) },
        processors => \&Test::Mutation::Host::processors,
    };
    $world->{detector_hints} = $hints if keys %$hints;
    return Test::Mutation::Signals::watch( sub { execute( plan( argv => $list, world => $world ), $world ) } );
}

# A closed stream is no terminal, and the question to it would warn.
sub _terminal ($stream) {
    return defined fileno $stream && -t $stream ? 1 : 0;    ## no critic (InputOutput::ProhibitInteractiveTest)
}

sub _unknown_command ($word) {
    my @names = ( map { $_->name } Test::Mutation::Commands::rows()->@* );
    push @names, map { $_->{words}->@* } Test::Mutation::Commands::switches()->@*;
    return Test::Mutation::Error::raise(
        'command-unknown',
        command => $word,
        nearest => Test::Mutation::Settings::nearest( $word, \@names )
    );
}

sub _operands ( $row, $parsed ) {
    my $operands = $parsed->{operands};
    my $grammar  = $row->operands;
    my %missing  = (
        identifier => sub { Test::Mutation::Error::raise('show-without-identifier') },
        execute    => sub { Test::Mutation::Error::raise('exec-without-command') },
        reports    => sub { Test::Mutation::Error::raise('merge-without-report') },
    );
    _unknown_command( $operands->[0] )
      if $grammar eq 'command' && $operands->@* && !Test::Mutation::Commands::of( $operands->[0] );
    my $missing_program = $grammar eq 'execute' && ( $parsed->{before_separator} != 1 || !length $operands->[1] );
    $missing{$grammar}->() if $operands->@* < $row->least || $missing_program;
    Test::Mutation::Error::raise( 'argument-unexpected', argument => $operands->[ $row->most ] )
      if defined $row->most && $operands->@* > $row->most;
    return;
}

# What an exception calls for: the exit status and the line for standard error.
sub _failure ( $error, $command ) {
    return { status => $error->exit_status, text => Test::Mutation::Message::line( $error->message ) }
      if $INTERRUPTION->check($error);
    my ( $kind, $text, $id ) =
      $TYPED->check($error)
      ? ( $error->kind, $error->message, $error->id )
      : ( 'internal', Test::Mutation::Message::text_of( 'internal-error', text => _first_line($error) ), q{} );
    my $outcome = $command eq 'exec' ? $OF_EXEC_COMMAND{$id} || $IN_EXEC{$kind} || $kind : $kind;
    return { status => Test::Mutation::Exit::of($outcome), text => Test::Mutation::Message::line($text) };
}

signature_for plan => ( named => [ argv => ArrayRef [Str], world => $WORLD ], returns => $INVOCATION );

sub plan ($arg) {
    my $attempt = Test::Mutation::Try::attempt( sub { _planned( $arg->argv, $arg->world ) } );
    return exists $attempt->{value} ? $attempt->{value} : { refused => _failure( $attempt->{error}, 'plan' ) };
}

sub _planned ( $argv, $world ) {
    my $parsed  = Test::Mutation::CLI::Arguments::parse( argv => $argv );
    my $command = $parsed->{command};
    my %plan    = (
        command    => $command,
        directory  => undef,
        config     => undef,
        operands   => $parsed->{operands},
        processors => undef
    );
    return \%plan if $parsed->{global};
    my $row = Test::Mutation::Commands::of($command);
    _operands( $row, $parsed );
    $plan{topic} = $plan{operands}[0] if $command eq 'help' && $plan{operands}->@*;
    return \%plan                     if $command eq 'help' || $command eq 'settings';

    # The directory comes first, so every later path and the configuration file are read from inside it.
    my $given  = $parsed->{given};
    my $root   = $given->{entries}{root};
    my $inside = $world->{cwd};
    if ($root) {
        my $directory = $plan{directory} = $root->{value};
        $inside = _under( $inside, $directory );
        my $reason = _closed($inside);
        Test::Mutation::Error::raise( 'directory-closed', directory => $directory, reason => $reason )
          if defined $reason;
    }
    if ( $command ne 'mutators' ) {
        Test::Mutation::Error::raise('working-directory-gone') if !defined $inside;
        $plan{processors} = $world->{processors}->();
        $plan{config}     = Test::Mutation::Settings::configure(
            root  => Cwd::abs_path($inside),
            given => $given,
            facts => {
                processors => $plan{processors}{count},
                env        => $world->{env},
                terminal   => $world->{out_tty} || $world->{err_tty}
            },
        );
    }
    if ( $row->operands eq 'paths' && $plan{operands}->@* ) {
        my $first = $plan{operands}[0];
        _unknown_command($first) if $parsed->{implicit} && $first !~ m{[./:]} && !-e _under( $inside, $first );
        if ( $command eq 'run' ) {
            $plan{paths} = Test::Mutation::Select::operand_paths( $plan{config}, $plan{operands} );
            return \%plan;
        }
        $plan{selection} = Test::Mutation::Select::resolve(
            config    => $plan{config},
            operands  => $plan{operands},
            read_only => 1
        );
    }
    return \%plan;
}

# A path as the command reads it once it stands in the directory.
# A process whose directory is gone has none, and an empty path names no file.
sub _under ( $directory, $path ) {
    return defined $directory && length $path ? File::Spec->rel2abs( $path, $directory ) : $path;
}

# The plan changes no directory, so it asks what a change of directory would answer.
sub _closed ($directory) {
    my $errno = !stat($directory) ? 0 + $! : !-d _ ? Errno::ENOTDIR : !-x _ ? Errno::EACCES : return;
    local $! = $errno;
    return "$!";
}

signature_for execute => ( positional => [ $INVOCATION, $WORLD ], returns => Int );

sub execute ( $invocation, $world ) {

    # The one place of the command that ends an exception: each kind has its status and its line.
    # A signal outranks every other outcome, so it ends the command whether it arrived in the plan, in the work, or after both.
    my $attempt = Test::Mutation::Try::attempt(
        sub {
            Test::Mutation::Signals::check();
            my $status = _carried_out( $invocation, $world );
            Test::Mutation::Signals::check();
            return $status;
        },
        'interruption'
    );
    return $attempt->{value} if exists $attempt->{value};
    my $failure = _failure( $attempt->{error}, $invocation->{command} );
    print { $world->{err} } $failure->{text};
    return $failure->{status};
}

sub _carried_out ( $invocation, $world ) {
    if ( my $refused = $invocation->{refused} ) {
        print { $world->{err} } $refused->{text};
        return $refused->{status};
    }
    my ( $command, $directory ) = $invocation->@{qw(command directory)};
    if ( defined $directory ) {
        my $reason = _closed( _under( $world->{cwd}, $directory ) );
        Test::Mutation::Error::raise( 'directory-closed', directory => $directory, reason => $reason )
          if defined $reason;
    }

    if ( $command eq 'version' ) {
        say { $world->{out} } "mutation $VERSION";
        return 0;
    }
    if ( $command eq 'help' ) {
        my $selected = $invocation->{topic};
        print { $world->{out} } _help( defined $selected ? Test::Mutation::Commands::of($selected) : undef );
        return 0;
    }
    return $COMMAND{$command}->( $invocation, $world );
}

# The first line of an exception without the place in the code that raised it.
# A value that has no text of its own gives the name of its type.
sub _first_line ($error) {
    my $says = Scalar::Util::blessed($error) && $error->can('message');
    return ref $error if ref $error && !$says && !overload::Method( $error, q{""} );
    my ($line) = ( split( /\n/, $says ? $error->message : "$error" ), q{} );
    return $line =~ s/ at \S+ line \d+[.]?\z//r;
}

sub _run ( $invocation, $world ) {
    require Test::Mutation::Runner;
    my $config   = $invocation->{config};
    my $listener = _progress( $invocation, $world );
    my $options  = { reports => 1, summary => $world->{env}{GITHUB_STEP_SUMMARY} };
    $options->{paths}          = $invocation->{paths}                      if exists $invocation->{paths};
    $options                   = { selection => $invocation->{selection} } if $invocation->{selection};
    $options->{detector_hints} = $world->{detector_hints}                  if exists $world->{detector_hints};
    my $result = Test::Mutation::Runner::run( $config, $listener, $options );
    _report( $result, $config, $world, $listener );
    return _concluded( $result, $config->min_score, $world );
}

sub _baseline ( $invocation, $world ) {
    require Test::Mutation::Runner;
    my $config = $invocation->{config};
    my $result = Test::Mutation::Runner::run( $config, _progress( $invocation, $world ), { baseline_only => 1 } );
    say { $world->{out} } 'Baseline: ', _plural( scalar $result->tests->@*, 'test' );
    say { $world->{err} } $_->{test} for $result->baseline_failures->@*;
    return _concluded( $result, undef, $world );
}

sub _settings ( $invocation, $world ) {
    for my $setting ( Test::Mutation::Settings::rows()->@* ) {
        say { $world->{out} } _option_words($setting), '  ', $setting->help, ' (default: ', $setting->default_text, ')';
    }
    return 0;
}

sub _color ( $config, $world, $terminal ) {
    return
         $config->color
      && !length( $world->{env}{NO_COLOR} )
      && ( $terminal || exists $config->specified->{color} ) ? 1 : 0;
}

sub _progress ( $invocation, $world ) {
    my $file = fileno $world->{err};
    my $defer =
      !$invocation->{config}->in_place && !$world->{err_tty} && defined $file && $file >= 0 && -f $world->{err};
    return Test::Mutation::Report::Live::listener(
        $world->{err}, $world->{err_tty}, _color( $invocation->{config}, $world, $world->{err_tty} ),
        $world->{clock},
        Test::Mutation::Host::describe( $invocation->{processors} ),
        $defer ? 1 : 0
    );
}

my %FILE_REPORT = ( json => 'mutation.json', html => 'mutation.html' );

sub _report ( $result, $config, $world, $listener = sub { return } ) {
    my %wanted = map { $_ => 1 } $config->format->@*;
    print { $world->{out} } Test::Mutation::Report::Terminal::render(
        $result,
        color => _color( $config, $world, $world->{out_tty} ),
        low   => $config->threshold_low,
        high  => $config->threshold_high,
        floor => $result->min_score
    ) if $wanted{terminal};

    my @formats = grep { $wanted{$_} } qw(json html);
    if (@formats) {
        my @written = _file_reports( $result, $config, \@formats );
        $listener->( 'report_written', { path => $_ } ) for @written;
        print { $world->{out} } 'Reports: ', join( ', ', @written ), "\n";
    }
    _report_to_github( $result, $world, $config ) if $config->github;
    return;
}

sub _file_reports ( $result, $config, $formats ) {
    require Test::Mutation::Report::Publication;
    my $directory = $config->report_dir;
    my $target    = File::Spec->rel2abs( $directory, $config->root );
    Test::Mutation::Tree::make($target);
    sysopen my $lock, $target, O_RDONLY
      or Test::Mutation::Error::raise( 'directory-unopenable', path => $directory, reason => "$!" );
    flock $lock, LOCK_EX or Test::Mutation::Error::raise( 'file-unwritable', path => $directory, reason => "$!" );
    my %output;
    for my $format (@$formats) {
        my $name = $FILE_REPORT{$format};
        $output{$format} = _stage_report( "$target/$name", "$directory/$name" );
    }
    my @thresholds = ( high => $config->threshold_high, low => $config->threshold_low );
    if ( $output{html} ) {
        require Test::Mutation::Report::Html;
        Test::Mutation::Report::Html::stream(
            $result, @thresholds,
            write => $output{html}{write},
            $output{json} ? ( write_json => $output{json}{write} ) : ()
        );
    }
    else {
        require Test::Mutation::Report::Json;
        Test::Mutation::Report::Json::stream( $result, @thresholds, write => $output{json}{write} );
    }
    _publish_report( $output{$_} ) for @$formats;
    my %digests = map { $FILE_REPORT{$_} => $output{$_}{digest}->hexdigest } @$formats;
    Test::Mutation::Report::Publication::record( $config->root, $target, \%digests );
    close $lock or Test::Mutation::Error::raise( 'file-unclosable', path => $directory, reason => "$!" );
    return map { $output{$_}{name} } @$formats;
}

sub _previous_report ( $directory, $select ) {
    my @reports;
    for my $format (qw(json html)) {
        my $path = "$directory/$FILE_REPORT{$format}";
        my ( $mode, $modified ) = ( Time::HiRes::stat($path) )[ 2, 9 ];
        push @reports, { path => $path, modified => $modified } if defined $mode && S_ISREG($mode);
    }
    for my $report ( sort { $b->{modified} <=> $a->{modified} } @reports ) {
        my $path = $report->{path};
        open my $file, '<:encoding(UTF-8)', $path
          or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
        my $text = do { local $/ = undef; readline $file };
        close $file or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
        next unless length $text;
        if ( $path =~ /[.]html\z/ ) {
            ($text) = $text =~ m{\Q<script id="report" type="application/json">\E (.+?) </script>}sx;
            next unless defined $text;
        }
        require Test::Mutation::Report::Json;
        my $parsed = Test::Mutation::Try::attempt( sub { Test::Mutation::Report::Json::parse($text) } );
        next unless exists $parsed->{value};
        my $selected = $select->( $parsed->{value} );
        return $selected if defined $selected;
    }
    return;
}

sub _summary_separator ( $path, $used ) {
    return q{} unless $used;
    my $previous = IO::File->new( $path, '<:raw' ) or return "\n";
    my $last     = seek( $previous, -1, SEEK_END ) ? getc $previous : undef;
    return defined $last && $last =~ /[\r\n]/ ? q{} : "\n";
}

sub _report_to_github ( $result, $world, $config ) {
    my $path = $world->{env}{GITHUB_STEP_SUMMARY};
    if ( defined $path && length $path ) {
        my @reports = map { File::Spec->catfile( $config->report_dir, $FILE_REPORT{$_} ) }
          grep { exists $FILE_REPORT{$_} } $config->format->@*;
        my $target = File::Spec->rel2abs( $path, $config->root );
        open my $file, '>>:raw:encoding(UTF-8)', $target
          or Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" );
        flock $file, LOCK_EX or Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" );
        my $used      = -s $file;
        my $separator = _summary_separator( $target, $used );
        my $markdown =
          Test::Mutation::Report::GitHub::summary( $result, $result->min_score, \@reports, $used + length $separator );
        print {$file} ( length $markdown ? $separator . $markdown : q{} )
          or Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" );
        close $file or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    }
    print { $world->{err} } Test::Mutation::Report::GitHub::annotations($result);
    return;
}

sub _stage_report ( $path, $name ) {
    require Digest::SHA;
    require Encode;
    $path = Cwd::abs_path($path) if -l $path;
    my $temporary = File::Temp->new( DIR => File::Basename::dirname($path), PERMS => oct '666' );
    if ( -f $path ) {
        chmod( ( stat $path )[2] & oct('777'), $temporary->filename )
          or Test::Mutation::Error::raise( 'file-unwritable', path => $name, reason => "$!" );
    }
    binmode $temporary, ':raw'
      or Test::Mutation::Error::raise( 'file-unwritable', path => $name, reason => "$!" );
    my $digest = Digest::SHA->new(256);
    return {
        path   => $path,
        name   => $name,
        file   => $temporary,
        digest => $digest,
        write  => sub ($chunk) {
            my $bytes = Encode::encode( 'UTF-8', $chunk );
            $digest->add($bytes);
            print {$temporary} $bytes
              or Test::Mutation::Error::raise( 'file-unwritable', path => $name, reason => "$!" );
        }
    };
}

sub _publish_report ($output) {
    my $file = $output->{file};
    close $file or Test::Mutation::Error::raise( 'file-unclosable', path => $output->{name}, reason => "$!" );
    rename $file->filename, $output->{path}
      or Test::Mutation::Error::raise( 'file-unrenamable', path => $output->{name}, reason => "$!" );
    return;
}

sub _ended ( $world, $status, $text ) {
    print { $world->{err} } Test::Mutation::Message::line($text);
    return $status;
}

# The outcome of a result: its exit status, and for every outcome but success the line that names it.
sub _concluded ( $result, $floor, $world ) {
    my $outcome = Test::Mutation::Outcome::of( $result, $floor );
    my $code    = $outcome->{exit}->code;
    return _ended( $world, $code, $outcome->{diagnostic} ) if defined $outcome->{diagnostic};
    return $code;
}

sub _list ( $invocation, $world ) {
    my $selected = $invocation->{selection}
      || Test::Mutation::Select::resolve( config => $invocation->{config}, read_only => 1 );
    my $previous = _previous_entries( $invocation->{config}, $selected->sources, $selected->mutants );
    for my $mutant ( $selected->mutants->@* ) {
        my $entry = $previous->{ $mutant->id };
        say { $world->{out} } Test::Mutation::Report::Results::heading($mutant), _suppression($mutant),
          $entry ? "  [$entry->{status}] " . _measured_at($entry) : q{};
    }
    say { $world->{out} } _plural( scalar $selected->mutants->@*, 'mutant' );
    return 0;
}

sub _previous_entries ( $config, $sources, $mutants ) {
    my $indexed = Test::Mutation::Store::History::entries( $config, $sources, $mutants );
    my %entries = %{ $indexed || {} };
    my %wanted  = map { $_->id => 1 } grep { !exists $entries{ $_->id } } @$mutants;
    return \%entries unless keys %wanted;
    my $directory = File::Spec->rel2abs( $config->report_dir, $config->root );
    _previous_report(
        $directory,
        sub ($prior) {
            my %same = map { $_ => 1 }
              grep { exists $prior->sources->{$_} && $prior->sources->{$_} eq $sources->{$_}->text }
              keys $sources->%*;
            for my $entry ( $prior->entries->@* ) {
                next if $entry->{status} eq 'Pending';
                my $mutant = $entry->{mutant};
                $entries{ $mutant->id } = { %$entry, finished => $prior->finished }
                  if $same{ $mutant->path } && delete $wanted{ $mutant->id };
            }
            return keys %wanted ? undef : \%entries;
        }
    );
    return \%entries;
}

sub _measured_at ($entry) {
    return POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime $entry->{finished} );
}

sub _suppression ($mutant) {
    my $reason = $mutant->suppression_reason;
    return
        !$mutant->suppressed ? q{}
      : defined $reason      ? "  (suppressed: $reason)"
      :                        '  (suppressed)';
}

sub _show ( $invocation, $world ) {
    my $selected = Test::Mutation::Select::resolve(
        config      => $invocation->{config},
        identifiers => $invocation->{operands},
        read_only   => 1
    );
    my $mutant   = $selected->mutants->[0];
    my $previous = _previous_entries( $invocation->{config}, $selected->sources, [$mutant] )->{ $mutant->id };
    say { $world->{out} } Test::Mutation::Report::Results::heading($mutant);
    say { $world->{out} } 'Last result: ', $previous ? $previous->{status} : 'unmeasured';
    if ($previous) {
        say { $world->{out} } 'Measured at: ', _measured_at($previous);
        say { $world->{out} } 'Reached by: ',
          $previous->{covered_by}->@* ? join( ', ', $previous->{covered_by}->@* ) : 'no test';
        if ( defined $previous->{by} ) {
            my $label = $previous->{status} eq 'Killed' ? 'Killed by' : 'Deciding test';
            say { $world->{out} } "$label: $previous->{by}";
        }
    }
    print { $world->{out} } Test::Mutation::Report::Patch::render(
        text   => $selected->sources->{ $mutant->path }->text,
        mutant => $mutant
    );
    return 0;
}

sub _exec ( $invocation, $world ) {
    require Test::Mutation::Runner;
    my $config = $invocation->{config};
    my ( $identifier, @command ) = $invocation->{operands}->@*;
    my $analysis = Test::Mutation::Runner::analyze($config);
    my $mutant   = Test::Mutation::Select::by_id( $analysis->{mutants}, $identifier );
    return Test::Mutation::Runner::run_command( $config, $analysis->{sources}{ $mutant->path }, $mutant, \@command );
}

sub _read_report ( $path, $root ) {
    require Test::Mutation::Report::Json;
    open my $handle, '<:encoding(UTF-8)', File::Spec->rel2abs( $path, $root )
      or Test::Mutation::Error::raise( 'input-unreadable', path => $path, reason => "$!" );
    local $/ = undef;
    my $text = readline $handle;
    close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    my $parsed =
      Test::Mutation::Try::attempt( sub { Test::Mutation::Report::Json::parse( defined $text ? $text : q{} ) } );
    return $parsed->{value} if exists $parsed->{value};
    return Test::Mutation::Error::raise( 'input-malformed', path => $path, reason => _first_line( $parsed->{error} ) );
}

sub _merge ( $invocation, $world ) {
    require Test::Mutation::Merge;
    my $config = $invocation->{config};
    my @parts  = map { { name => $_, result => _read_report( $_, $config->root ) } } $invocation->{operands}->@*;
    my $result = Test::Mutation::Merge::merge( \@parts, $config->min_score );
    Test::Mutation::Select::outputs( $config, $world->{env}{GITHUB_STEP_SUMMARY} );
    _report( $result, $config, $world );
    if ( $config->cache ) {
        my %measured;
        for my $part (@parts) {
            my $shard = $part->{result};
            $measured{ $_->{mutant}->id } = $shard->finished for $shard->entries->@*;
        }
        Test::Mutation::Store::History::record( $config, $result, 1,
            { completed => Time::HiRes::time(), measured => \%measured } );
    }
    return _concluded( $result, $result->min_score, $world );
}

sub _mutators ( $invocation, $world ) {
    my @mutators = Test::Mutation::Mutator::Catalog::mutators()->@*;
    my $name     = List::Util::max( map { length $_->name } @mutators );
    my $profile  = List::Util::max( map { length $_->profile } @mutators );
    printf { $world->{out} } "%-*s  %-*s  %s\n", $name, $_->name, $profile, $_->profile, $_->description for @mutators;
    return 0;
}

sub _plural ( $count, $noun ) {
    return $count == 1 ? "$count $noun" : "$count ${noun}s";
}

1;

__END__

=head1 NAME

Test::Mutation::CLI - the mutation command

=head1 SYNOPSIS

    exit Test::Mutation::CLI::main(@ARGV);

=head1 FUNCTIONS

=head2 main

Runs the command named by the first argument, C<run> when there is none, and returns the exit status.
The call plans with the facts of the process and then carries the plan out.

=head2 main_with_detector_hints

Runs a complete uncached measurement with suggested covering tests keyed by mutant ID.
The remaining arguments use the same command syntax as C<main>.
Only a fresh observation can detect a mutant.

=head2 plan

    my $invocation = Test::Mutation::CLI::plan( argv => \@ARGV, world => $world );

Returns what the command would do, and changes nothing: no directory, no search path, and no file.
C<world> holds the facts that the command reads from its process.
C<cwd> is the working directory, C<env> the environment, and C<out> and C<err> are the handles of the two streams.
C<out_tty> and C<err_tty> state whether a stream is a terminal.
C<clock> returns the time.
C<processors> returns the count of processors that a run may use and its source, as L<Test::Mutation::Host/processors> does.

A plan to act holds the C<command>, the C<directory> that C<--root> names, the C<config>, and the C<operands>.
A plan with settings also holds the C<processors> of its world, and a run names them in its first line.
A plan to refuse holds C<refused>, with the exit C<status> and the C<text> for standard error.
L<Test::Mutation::CLI::Arguments> reads the words, and L<Test::Mutation::Settings> reads the configuration file and builds the C<config>.
The help text lists the options of the table of the settings.
The function dies on an error that no check of the arguments foresees.

=head2 execute

    my $status = Test::Mutation::CLI::execute( $invocation, $world );

Carries a plan out and returns the exit status.
A plan to refuse prints its text.
A plan to act resolves paths against the project directory and prints to the streams of the world.

=cut
