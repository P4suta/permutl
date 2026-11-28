package AuthorSection;
use strict;
use warnings;

sub authors {
    my @authors;
    for (@_) {
        next unless /^=head1 AUTHORS/ ... /^=/;
        next if /^=/;
        push @authors, $_;
    }
    return \@authors;
}

sub unfinished {
    ...;
    return 'ready';
}

1;
