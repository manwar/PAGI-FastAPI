#!/usr/bin/env perl

use v5.38;
use Test::More;
use experimental 'class';

use PAGI::FastAPI::Response::SSE;
use Future;
use Future::AsyncAwait;
use PAGI::Test::ConnectionState;

class MockPagiSSEChannel {
    field $events_sent = [];
    field $state       = 'open';

    async method send ($event) {
        push @$events_sent, $event;
        if ($event->{type} eq 'sse.close') {
            $state = 'closed';
        }
    }

    async method receive () {
        return Future->new;
    }

    method get_sent_events () { return $events_sent }
}

subtest 'PAGI::SSE Dispatcher - Connection Initialization' => sub {
    my $mock_channel = MockPagiSSEChannel->new;

    # PAGI Www 0.6: the scope carries pagi.connection; sse.close completes it.
    my $conn    = PAGI::Test::ConnectionState->new;
    my $scope   = { type => 'sse', path => '/stream', 'pagi.connection' => $conn };
    my $receive = sub { $mock_channel->receive };
    my $send    = sub ($evt) {
        my $sent = $mock_channel->send($evt);
        $conn->_mark_complete if $evt->{type} eq 'sse.close';
        return $sent;
    };

    my $response = PAGI::FastAPI::Response::SSE->new(
        status    => 200,
        headers   => [ ['x-custom-header' => 'test-val'] ],
        generator => async sub ($sse) {
            await $sse->send("hello world");
            await $sse->close(reason => 'test_done');
        },
    );

    $response->dispatch($scope, $receive, $send)->get;

    my $sent = $mock_channel->get_sent_events;

    # 1. Verify sse.start event headers
    is($sent->[0]{type}, 'sse.start', 'First event sent is sse.start');
    is($sent->[0]{status}, 200, 'Status code 200 passed through');

    my %headers = map { $_->[0] => $_->[1] } @{$sent->[0]{headers}};
    is($headers{'x-accel-buffering'}, 'no', 'Nginx buffering header disabled');
    is($headers{'x-custom-header'}, 'test-val', 'Custom headers merged correctly');

    # 2. Verify data payload
    is($sent->[1]{type}, 'sse.send', 'Second event sent is sse.send');
    is($sent->[1]{data}, 'hello world', 'Data string matched expected payload');

    # 3. Verify close event
    is($sent->[2]{type}, 'sse.close', 'Final event sent is sse.close');
    is($sent->[2]{reason}, 'test_done', 'Close reason passed to transport');
};

subtest 'PAGI::SSE Features - JSON, Custom Events, and Keepalives' => sub {
    my $mock_channel = MockPagiSSEChannel->new;

    # PAGI Www 0.6: the scope carries pagi.connection; sse.close completes it.
    my $conn    = PAGI::Test::ConnectionState->new;
    my $scope   = { type => 'sse', path => '/live', 'pagi.connection' => $conn };
    my $receive = sub { $mock_channel->receive };
    my $send    = sub ($evt) {
        my $sent = $mock_channel->send($evt);
        $conn->_mark_complete if $evt->{type} eq 'sse.close';
        return $sent;
    };

    my $response = PAGI::FastAPI::Response::SSE->new(
        generator => async sub ($sse) {
            # Send keepalive ping request
            await $sse->keepalive(15);

            # Send structured JSON event
            await $sse->send_event(
                event => 'token',
                id    => 'msg-1',
                data  => { word => 'PAGI', score => 99 },
            );

            await $sse->close;
        },
    );

    $response->dispatch($scope, $receive, $send)->get;

    my $sent = $mock_channel->get_sent_events;

    # Assert keepalive registration
    is($sent->[1]{type}, 'sse.keepalive', 'Keepalive event issued');
    is($sent->[1]{interval}, 15, 'Keepalive interval set to 15 seconds');

    # Assert structured event
    is($sent->[2]{type}, 'sse.send', 'Structured event sent');
    is($sent->[2]{event}, 'token', 'Event type specified');
    is($sent->[2]{id}, 'msg-1', 'Event ID set');
    like($sent->[2]{data}, qr/"word":"PAGI"/, 'Data automatically encoded as JSON');
};

subtest 'PAGI::SSE Cleanup & Error Handling' => sub {
    my $mock_channel = MockPagiSSEChannel->new;

    # PAGI Www 0.6: the scope carries pagi.connection; sse.close completes it.
    my $conn    = PAGI::Test::ConnectionState->new;
    my $scope   = { type => 'sse', path => '/stream', 'pagi.connection' => $conn };
    my $receive = sub { $mock_channel->receive };
    my $send    = sub ($evt) {
        my $sent = $mock_channel->send($evt);
        $conn->_mark_complete if $evt->{type} eq 'sse.close';
        return $sent;
    };

    my $cleanup_ran = 0;

    my $response = PAGI::FastAPI::Response::SSE->new(
        generator => async sub ($sse) {
            # Register close callback
            # PAGI-Tools 0.003000 passes ($sse, $reason, $detail).
            $sse->on_close(sub ($s, $reason, $detail = undef) {
                $cleanup_ran = 1;
            });

            await $sse->send("ping");
            await $sse->close(reason => 'app_closed');
        },
    );

    $response->dispatch($scope, $receive, $send)->get;

    ok($cleanup_ran, 'on_close lifecycle hook executed upon completion');
};

# A generator's failure while the client is still there is an application
# error: it must reach the server, which ends the stream and logs it. A
# client that left mid-stream is not one.
sub dispatch_with ($generator, %opt) {
    my $conn  = PAGI::Test::ConnectionState->new;
    my $scope = { type => 'sse', path => '/stream', 'pagi.connection' => $conn };
    my $client_leaves = Future->new;
    my $receive = sub { $client_leaves->then(sub { Future->done({ type => 'sse.disconnect' }) }) };
    my @sent;
    my $send = sub ($evt) { push @sent, $evt->{type}; Future->done };
    my $f = PAGI::FastAPI::Response::SSE->new(generator => $generator)
        ->dispatch($scope, $receive, $send);
    return ($f, \@sent, $conn);
}

subtest 'A generator that dies while the client is connected surfaces its error' => sub {
    my ($f, $sent) = dispatch_with(async sub ($sse) {
        await $sse->send_event(data => 'one');
        die "generator bug\n";
    });
    ok($f->is_ready, 'dispatch does not leave the stream open');
    is(($f->failure)[0], "generator bug\n", 'it fails with the generator\'s error');
    is_deeply($sent, ['sse.start', 'sse.send'], 'the event before the error went out');
};

subtest 'A plain (non-async) generator gets the diagnostic' => sub {
    my ($f) = dispatch_with(sub ($sse) { return 1 });
    ok($f->is_ready, 'dispatch does not leave the stream open');
    like(($f->failure)[0] // '', qr/SSE generator must be an 'async sub \(\$sse\)'/,
        'the "did you forget async" message reaches the caller');
};

subtest 'A client that leaves mid-stream ends it quietly' => sub {
    my ($f, $sent, $conn);
    ($f, $sent, $conn) = dispatch_with(async sub ($sse) {
        await $sse->send_event(data => 'one');
        $sse->scope->{'pagi.connection'}->_mark_disconnected('client_closed');
        await $sse->send_event(data => 'two');    # the client has gone
    });
    ok($f->is_ready, 'dispatch finishes');
    ok(!$f->is_failed, 'without an error') or diag(($f->failure)[0]);
};

done_testing;
