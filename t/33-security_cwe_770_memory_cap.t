#!/usr/bin/env perl

use v5.38;
use Test::More;
use PAGI::FastAPI::RateLimit::Driver::Memory;

my $driver = PAGI::FastAPI::RateLimit::Driver::Memory->new(max_keys => 100);

# Insert 1,000 distinct fake keys
for my $i (1 .. 1000) {
    $driver->increment_async("fake_key_$i", 60)->get;
}

# Verify storage is capped via driver instance method
cmp_ok($driver->count(), '<=', 100, 'Memory storage key count capped at max_keys limit');

done_testing;
