use strict;
use warnings;

use Test::More;
use Test::Stream::Tester;

use ok 'Test::Stream::Spec';
my $CLASS = 'Test::Stream::Spec';

my %L;

my $one = $CLASS->new( name => 'root' ); $L{'root'} = __LINE__;

$one->push_subtest('a test' => sub {
    my $arg = shift;
    ok(1, "a test A"); BEGIN { $L{'a test A'} = __LINE__ };
    ok(1, "a test B"); BEGIN { $L{'a test B'} = __LINE__ };
    is($arg, 'The Arg', "Got the arg"); BEGIN { $L{'arg test'} = __LINE__ };
}); $L{'a test'} = __LINE__;

my $two = $CLASS->new( name => 'child' ); $L{child} = __LINE__;
$two->push_subtest('b test', {skip => 'foo'}, sub {
    my $arg = shift;
    ok(1, "b test A");
    ok(0, "b test B");
    is($arg, 'The Arg', "Got the arg");
}); $L{'b test'} = __LINE__;

$one->push_spec($two);

$one->push_multiplier('a mult A' => sub { 1 }); $L{'a mult A'} = __LINE__;
$one->push_multiplier('a mult B' => sub { 1 }); $L{'a mult B'} = __LINE__;

$one->push_pre_test( 'pre-t'   => sub { die 'foo' if $_[0] eq 'bail'  });      $L{'pre-t'} = __LINE__;
$one->push_post_test('post-t'  => sub { 'post' });      $L{'post-t'} = __LINE__;
$one->push_wrap_test('wrap-t'  => sub { $_[0]->(@_) }); $L{'wrap-t'} = __LINE__;
$one->push_pre_test( 'pre-tx'  => sub { 'pre'  });      $L{'pre-tx'} = __LINE__;
$one->push_post_test('post-tx' => sub { 'post' });      $L{'post-tx'} = __LINE__;
$one->push_wrap_test('wrap-tx' => sub { $_[0]->(@_) }); $L{'wrap-tx'} = __LINE__;

$one->push_pre_mult('pre-m'   => sub { 1 }); $L{'pre-m'}  = __LINE__;
$one->push_post_mult('post-m' => sub { 1 }); $L{'post-m'} = __LINE__;

$one->push_pre_all('pre-a'   => sub { 1 }); $L{'pre-a'}  = __LINE__;
$one->push_post_all('post-a' => sub { 1 }); $L{'post-a'} = __LINE__;

my $check = check {
    event note => {message => 'Running: pre-a', file => __FILE__, line => $L{'pre-a'}};
    event note => {message => 'Subtest: root',  file => __FILE__, line => $L{'root'}};
    event subtest => {
        name   => 'root',
        pass   => 1,
        file   => __FILE__,
        line   => $L{'root'},
        events => check {
            event note => {message => 'Running: pre-m',    file => __FILE__, line => $L{'pre-m'}};
            event note => {message => 'Subtest: a mult A', file => __FILE__, line => $L{'a mult A'}};
            event subtest => {
                name   => 'a mult A',
                pass   => 1,
                file => __FILE__,
                line => $L{'a mult A'},
                events => check {
                    event note => {message => 'Running: pre-t',    file => __FILE__, line => $L{'pre-t'}};
                    event note => {message => 'Entering: wrap-t',  file => __FILE__, line => $L{'wrap-t'}};
                    event note => {message => 'Running: pre-tx',   file => __FILE__, line => $L{'pre-tx'}};
                    event note => {message => 'Entering: wrap-tx', file => __FILE__, line => $L{'wrap-tx'}};

                    event note => {message => 'Subtest: a test', file => __FILE__, line => $L{'a test'}};

                    event subtest => {
                        name   => 'a test',
                        pass   => 1,
                        file   => __FILE__,
                        line   => $L{'a test'},
                        events => check {
                            event ok => {name => 'a test A',    pass => 1, file => __FILE__, line => $L{'a test A'}};
                            event ok => {name => 'a test B',    pass => 1, file => __FILE__, line => $L{'a test B'}};
                            event ok => {name => 'Got the arg', pass => 1, file => __FILE__, line => $L{'arg test'}};
                            event plan => {max => 3, file => __FILE__, line => $L{'a test'}};
                        },
                    };

                    event note => {message => 'Running: post-t',  file => __FILE__, line => $L{'post-t'}};
                    event note => {message => 'Leaving: wrap-tx', file => __FILE__, line => $L{'wrap-tx'}};
                    event note => {message => 'Running: post-tx', file => __FILE__, line => $L{'post-tx'}};
                    event note => {message => 'Leaving: wrap-t',  file => __FILE__, line => $L{'wrap-t'}};

                    event note => {message => 'Subtest: child', file => __FILE__, line => $L{'child'}};

                    event subtest => {
                        name   => 'child',
                        pass   => 1,
                        file   => __FILE__,
                        line   => $L{'child'},
                        events => check {
                            event ok => {name => 'b test', pass => 1, skip => 'foo', file => __FILE__, line => $L{'b test'}};
                            event plan => {max => 1, file => __FILE__, line => $L{'child'}};
                        },
                    };

                    event plan => {max => 2, file => __FILE__, line => $L{'a mult A'}};
                },
            };
            event note => {message => 'Running: post-m', file => __FILE__, line => $L{'post-m'}};

            event note => {message => 'Running: pre-m', file => __FILE__, line => $L{'pre-m'}};
            event note => {message => 'Subtest: a mult B', file => __FILE__, line => $L{'a mult B'}};
            event subtest => {
                name   => 'a mult B',
                pass   => 1,
                file => __FILE__,
                line => $L{'a mult B'},
                events => check {
                    event note => {message => 'Running: pre-t',    file => __FILE__, line => $L{'pre-t'}};
                    event note => {message => 'Entering: wrap-t',  file => __FILE__, line => $L{'wrap-t'}};
                    event note => {message => 'Running: pre-tx',   file => __FILE__, line => $L{'pre-tx'}};
                    event note => {message => 'Entering: wrap-tx', file => __FILE__, line => $L{'wrap-tx'}};

                    event note => {message => 'Subtest: a test', file => __FILE__, line => $L{'a test'}};

                    event subtest => {
                        name   => 'a test',
                        pass   => 1,
                        file   => __FILE__,
                        line   => $L{'a test'},
                        events => check {
                            event ok => {name => 'a test A',    pass => 1, file => __FILE__, line => $L{'a test A'}};
                            event ok => {name => 'a test B',    pass => 1, file => __FILE__, line => $L{'a test B'}};
                            event ok => {name => 'Got the arg', pass => 1, file => __FILE__, line => $L{'arg test'}};
                            event plan => {max => 3, file => __FILE__, line => $L{'a test'}};
                        },
                    };

                    event note => {message => 'Running: post-t',  file => __FILE__, line => $L{'post-t'}};
                    event note => {message => 'Leaving: wrap-tx', file => __FILE__, line => $L{'wrap-tx'}};
                    event note => {message => 'Running: post-tx', file => __FILE__, line => $L{'post-tx'}};
                    event note => {message => 'Leaving: wrap-t',  file => __FILE__, line => $L{'wrap-t'}};

                    event note => {message => 'Subtest: child', file => __FILE__, line => $L{'child'}};

                    event subtest => {
                        name   => 'child',
                        pass   => 1,
                        file   => __FILE__,
                        line   => $L{'child'},
                        events => check {
                            event ok => {name => 'b test', pass => 1, skip => 'foo', file => __FILE__, line => $L{'b test'}};
                            event plan => {max => 1, file => __FILE__, line => $L{'child'}};
                        },
                    };

                    event plan => {max => 2, file => __FILE__, line => $L{'a mult B'}};
                },
            };
            event note => {message => 'Running: post-m', file => __FILE__, line => $L{'post-m'}};
        },
    };
    event note => {message => 'Running: post-a', file => __FILE__, line => $L{'post-a'}};
};

events_are(
    intercept { $one->run(args => ['bail']) },
    check {
        directive seek => 1;
        event bail => {};
    },
    "Bail on setup/teardown exception"
);

events_are(
    intercept { $one->run(args => ['The Arg']) },
    $check,
    "Events are as expected"
);

events_are(
    intercept { $one->run(args => ['The Arg']) },
    $check,
    "Spec is reusable"
);

done_testing;
