package Test::Mutation::Store::Analysis;
use v5.36;
use Cpanel::JSON::XS ();
use Types::Standard  qw(ArrayRef Dict HashRef InstanceOf Int Maybe Str Tuple Undef);
use Type::Params     qw(signature_for);
use Test::Mutation::Mutant;
use Test::Mutation::Store;
use Test::Mutation::Types qw(Refusal Rejected);

our $VERSION = '0.001';

my $JSON = Cpanel::JSON::XS->new->canonical;
my $FILE = Dict [
    problem  => Maybe [Str],
    left_out => Int,
    rejected => ArrayRef [Rejected],
    refusals => ArrayRef [Refusal],
    mutants  => ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ]
];

signature_for read_file => ( positional => [ InstanceOf ['DBI::db'], Str, ArrayRef [Str] ], returns => Maybe [$FILE] );

sub read_file ( $db, $identity, $prefixes ) {
    return read_files( $db, [$identity], $prefixes )->{$identity};
}

signature_for read_files => (
    positional => [ InstanceOf ['DBI::db'], ArrayRef [Str], ArrayRef [Str] ],
    returns    => HashRef [$FILE],
);

sub read_files ( $db, $identities, $prefixes ) {
    my @remaining = @$identities;
    my %files;
    while (@remaining) {
        my @group = splice @remaining, 0, 64;
        _read_group( $db, \@group, $prefixes, \%files );
    }
    return \%files;
}

sub _read_group ( $db, $identities, $prefixes, $files ) {
    my $slots   = join ',', ('?') x @$identities;
    my $catalog = $db->prepare("SELECT identity,facts FROM analysis WHERE identity IN ($slots)");
    $catalog->execute(@$identities);
    my @hits;
    while ( my ( $id, $text ) = $catalog->fetchrow_array ) {
        push @hits, $id;
        $files->{$id} = { $JSON->decode($text)->%*, mutants => [] };
    }
    return unless @hits;
    unless (@$prefixes) {
        my $select =
          $db->prepare("SELECT analysis,data FROM candidate WHERE analysis IN ($slots) ORDER BY analysis,ordinal");
        $select->execute(@$identities);
        while ( my ( $id, $data ) = $select->fetchrow_array ) {
            push $files->{$id}{mutants}->@*, Test::Mutation::Mutant->new( $JSON->decode($data) );
        }
        return;
    }
    my $rows = _candidate_rows( $db, \@hits, $prefixes );
    for my $id ( keys %$rows ) {
        $files->{$id}{mutants} = [
            map  { Test::Mutation::Mutant->new( $JSON->decode( $rows->{$id}{$_} ) ) }
            sort { $a <=> $b } keys $rows->{$id}->%*
        ];
    }
    return;
}

sub _candidate_rows ( $db, $analyses, $prefixes ) {
    my $hits = join ',', ('?') x @$analyses;
    my %rows;
    my $read = sub ( $filter, @parameters ) {
        my $select = $db->prepare("SELECT analysis,ordinal,data FROM candidate WHERE analysis IN ($hits)$filter");
        $select->execute( @$analyses, @parameters );
        while ( my ( $id, $ordinal, $data ) = $select->fetchrow_array ) { $rows{$id}{$ordinal} = $data }
        return;
    };
    my %wanted = map  { $_ => 1 } grep { /\A[0-9a-f]{1,12}\z/ } @$prefixes;
    my @exact  = grep { length($_) == 12 } keys %wanted;
    while (@exact) {
        my @ids = splice @exact, 0, 500;
        $read->( ' AND id IN (' . join( ',', ('?') x @ids ) . ')', @ids );
    }
    my @patterns = map { "$_*" } grep { length($_) < 12 } keys %wanted;
    while (@patterns) {
        my @group = splice @patterns, 0, 64;
        $read->( ' AND (' . join( ' OR ', ('id GLOB ?') x @group ) . ')', @group );
    }
    return \%rows;
}

signature_for publish => ( positional => [ Str, ArrayRef [ Tuple [ Str, $FILE ] ] ], returns => Undef );

sub publish ( $path, $pending ) {
    my $db = Test::Mutation::Store::database($path);
    Test::Mutation::Store::transaction(
        $db,
        sub {
            my $file      = $db->prepare('INSERT OR IGNORE INTO analysis VALUES (?,?)');
            my $candidate = $db->prepare('INSERT INTO candidate VALUES (?,?,?,?)');
            for my $queued (@$pending) {
                my ( $identity, $result ) = @$queued;
                my %facts   = %$result;
                my $mutants = delete $facts{mutants};
                next if $file->execute( $identity, $JSON->encode( \%facts ) ) == 0;
                my $order = 0;
                for my $mutant (@$mutants) {
                    $candidate->execute( $identity, $order++, $mutant->id, $JSON->encode( { $mutant->%* } ) );
                }
            }
            return;
        }
    );
    return;
}

1;

__END__

=head1 NAME

Test::Mutation::Store::Analysis - index generated mutants by file analysis and identifier

=head1 FUNCTIONS

=head2 read_file

Returns the facts for a matching analysis and the mutants matching the requested prefixes in inventory order.
An empty prefix list selects the whole file.

=head2 read_files

Returns the matching file analyses by identity with candidates in inventory order.

=head2 publish

Commits the facts and generated mutants of each previously unseen file analysis.

=cut
