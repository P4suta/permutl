use v5.38;
use experimental 'class';
use feature 'say';
class Counter 1.0 {
    field $count :param = 0;
    field $limit = 10 + 5;

    ADJUST {
        $limit = $limit + 5;
    }

    method bump ( $by = 1 ) {
        $count += $by;
        return $self;
    }

    method count { return $count }

    method limit { return $limit }

    method size { return 10 > 5 ? 'big' : 'small' }
}

1;
