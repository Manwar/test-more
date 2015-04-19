use strict;
use warnings;

use Test::More tests => 5;
use Test::Stream::Tester;

use ok 'Test::Stream::Spec' => (
    qw/build_spec spec/
);
my $CLASS = 'Test::Stream::Spec';

can_ok(__PACKAGE__, qw/build_spec spec/);

my $spec = spec(__PACKAGE__);
isa_ok($spec, $CLASS);

build_spec $spec => sub {
    my $spec = spec(__PACKAGE__);
    $spec->push_subtest(foo => sub {
        ok(1, 'bar');
    });
};

events_are(
    intercept {
        $CLASS->follow;
        done_testing;
    },
    check {
        event note => { message => 'Subtest: main' };
        event subtest => {
            pass => 1,
            name => 'main',
            events => check {
                event note => { message => 'Subtest: foo' };
                event subtest => {
                    pass => 1,
                    name => 'foo',
                    events => check {
                        event ok => { name => 'bar' };
                        event plan => { max => 1 };
                    },
                };
                event plan => { max => 1 };
            },
        };
        event plan => { max => 1 };
    },
    "Ran via done_testing"
);

# Now lets see if it runs via the end block.
$CLASS->follow;

# DO NOT USE done_testing!
