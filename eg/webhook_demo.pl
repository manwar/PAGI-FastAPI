#!/usr/bin/env perl

# Start the server:
#   pagi-server eg/webhook_demo.pl
#
# Access Web UI:
#   Open http://127.0.0.1:5000/ in your browser

use v5.38;
use HTTP::Tiny;
use PAGI::FastAPI;
use Future::AsyncAwait;
use JSON::PP qw(encode_json);
use Digest::SHA qw(hmac_sha256_hex);

my $SHARED_SECRET = 'my_shared_secret';

my $app = PAGI::FastAPI->new(
    title   => 'PAGI::FastAPI Webhook Dashboard',
    version => '1.0.0',
);

# In-memory data stores
my @subscribers;
my @delivery_logs;

my $html_content = do { local $/; <DATA> };
$app->get('/',
    summary => 'Serve Webhook Management Dashboard',
    handler => async sub ($c) { $c->html($html_content); },
);

$app->post('/webhooks/subscribe',
    summary => 'Register a new webhook target endpoint',
    handler => async sub ($c) {
        my $body       = $c->body // {};
        my $target_url = $body->{target_url};
        my $secret     = $body->{secret} // 'default_secret';

        unless ($target_url) {
            $c->status(400);
            return { error => 'Missing target_url in request body' };
        }

        my $sub = {
            id         => scalar(@subscribers) + 1,
            target_url => $target_url,
            secret     => $secret,
            created_at => time(),
        };

        push @subscribers, $sub;

        unshift @delivery_logs, {
            timestamp  => scalar(localtime),
            event      => 'subscriber.created',
            target     => $target_url,
            status     => 200,
            status_msg => "Subscriber Registered (ID: $sub->{id})",
            details    => {
                subscriber_id => $sub->{id},
                target_url    => $target_url,
                secret_key    => '*' x length($secret),
            },
        };

        return {
            status     => 'subscribed',
            subscriber => $sub,
        };
    }
);

$app->post('/events/trigger',
    summary => 'Simulate a domain event that dispatches webhooks to all subscribers',
    handler => async sub ($c) {
        my $body       = $c->body // {};
        my $event_type = $body->{event_type};

        my $payload = {
            event_id   => 'evt_' . time(),
            event_type => $event_type,
            timestamp  => time(),
            data       => {
                user_id => 101,
                message => "Action $event_type successfully processed",
            },
        };

        my $json_formatter = JSON::PP->new->canonical(1)->utf8(1);
        my $json_payload   = $json_formatter->encode($payload);
        my $dispatched_count = 0;
        my $ua = HTTP::Tiny->new(timeout => 5);

        for my $sub (@subscribers) {
            my $signature = hmac_sha256_hex($json_payload, $sub->{secret});

            my $res = $ua->post($sub->{target_url}, {
                headers => {
                    'Content-Type'     => 'application/json',
                    'X-PAGI-Signature' => $signature,
                    'X-PAGI-Event'     => $event_type,
                },
                content => $json_payload,
            });

            if ($res->{success}) {
                $dispatched_count++;
            }
        }

        return {
            status     => 'dispatched',
            event      => $payload,
            delivered  => $dispatched_count,
            total_subs => scalar(@subscribers),
        };
    }
);

$app->post('/webhooks/incoming',
    summary => 'Endpoint that receives, verifies, and consumes incoming webhooks',
    handler => async sub ($c) {
        my $data      = $c->body // {};
        my $event     = $c->header('x-pagi-event')     // $c->header('X-PAGI-Event')     // 'unknown';
        my $signature = $c->header('x-pagi-signature') // $c->header('X-PAGI-Signature') // '';

        my $json_formatter = JSON::PP->new->canonical(1)->utf8(1);
        my $raw_body       = $json_formatter->encode($data);

        my $matched = 0;
        my $expected_sig = '';

        my @secrets = map { $_->{secret} } @subscribers;
        push @secrets, $SHARED_SECRET unless @secrets;

        for my $sec (@secrets) {
            my $candidate_sig = hmac_sha256_hex($raw_body, $sec);
            if (constant_time_eq($signature, $candidate_sig)) {
                $matched = 1;
                $expected_sig = $candidate_sig;
            }
        }

        my $status_code = $matched ? 200 : 401;
        my $status_msg  = $matched ? 'Verified & Accepted' : 'Signature Verification Failed';

        unless ($matched) {
            $c->status(401);
        }

        unshift @delivery_logs, {
            timestamp  => scalar(localtime),
            event      => $event,
            target     => '/webhooks/incoming',
            status     => $status_code,
            status_msg => $status_msg,
            details    => { payload => $data },
        };

        return { status => $status_msg, event => $event };
    }
);

$app->get('/webhooks/logs',
    summary => 'Retrieve current delivery logs',
    handler => async sub ($c) {
        return \@delivery_logs;
    }
);

$app->to_app;

sub constant_time_eq ($a, $b) {
    return 0 unless length($a) == length($b);

    # Unpack strings into real byte arrays
    my @a_bytes = unpack('C*', $a);
    my @b_bytes = unpack('C*', $b);

    my $diff = 0;

    for (my $i = 0; $i < @a_bytes; $i++) {
        $diff |= $a_bytes[$i] ^ $b_bytes[$i];
    }

    return $diff == 0;
}

__DATA__
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>PAGI Webhook Dashboard</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 30px; background: #f4f6f8; color: #333; }
        .container { max-width: 900px; margin: 0 auto; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 20px; }
        h1, h2 { margin-top: 0; color: #2c3e50; }
        label { display: block; margin-top: 10px; font-weight: bold; }
        input, select, button { width: 100%; padding: 10px; margin-top: 5px; border: 1px solid #ccc; border-radius: 4px; box-sizing: border-box; }
        button { background: #3498db; color: white; font-weight: bold; border: none; cursor: pointer; margin-top: 15px; }
        button:hover { background: #2980b9; }
        pre { background: #272822; color: #f8f8f2; padding: 15px; border-radius: 5px; overflow-x: auto; font-size: 13px; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
        .log-entry { border-left: 4px solid #3498db; background: #f8f9fa; padding: 10px; margin-bottom: 10px; border-radius: 0 4px 4px 0; }
        .status-200 { border-color: #2ecc71; }
        .status-401 { border-color: #e74c3c; }
    </style>
</head>
<body>
<div class="container">
    <h1>PAGI Webhook Dashboard</h1>

    <div class="grid">
        <!-- Subscription Form -->
        <div class="card">
            <h2>1. Register Webhook</h2>
            <form id="subForm">
                <label>Target URL</label>
                <input type="url" id="target_url" value="http://127.0.0.1:5000/webhooks/incoming" required>

                <label>Secret Key</label>
                <input type="text" id="secret" value="my_shared_secret" required>

                <button type="submit">Subscribe Endpoint</button>
            </form>
        </div>

        <!-- Trigger Event Form -->
        <div class="card">
            <h2>2. Trigger Event</h2>
            <form id="triggerForm">
                <label>Event Type</label>
                <select id="event_type">
                    <option value="user.signup">user.signup</option>
                    <option value="order.created">order.created</option>
                    <option value="payment.completed">payment.completed</option>
                </select>

                <button type="submit" style="background:#2ecc71;">Dispatch Event</button>
            </form>
        </div>
    </div>

    <!-- Output Logs -->
    <div class="card">
        <h2>Delivery & Verification Feed</h2>
        <div id="logs"><p style="color:#7f8c8d;">No events dispatched yet.</p></div>
    </div>
</div>

<script>
    document.getElementById('subForm').addEventListener('submit', async (e) => {
        e.preventDefault();
        await fetch('/webhooks/subscribe', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                target_url: document.getElementById('target_url').value,
                secret: document.getElementById('secret').value
            })
        });
        refreshLogs();
    });

    document.getElementById('triggerForm').addEventListener('submit', async (e) => {
        e.preventDefault();
        const selectedEvent = document.getElementById('event_type').value;

        const res = await fetch('/events/trigger', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ event_type: selectedEvent })
        });
        await res.json();
        refreshLogs();
    });

    async function refreshLogs() {
        const res = await fetch('/webhooks/logs');
        const logs = await res.json();
        const logContainer = document.getElementById('logs');
        if (logs.length === 0) return;

        // Helper to deeply sort object keys for canonical JSON rendering
        function canonicalize(obj) {
            if (obj === null || typeof obj !== 'object') return obj;
            if (Array.isArray(obj)) return obj.map(canonicalize);
            return Object.keys(obj).sort().reduce((acc, key) => {
                acc[key] = canonicalize(obj[key]);
                return acc;
            }, {});
        }

        logContainer.innerHTML = logs.map(l => `
            <div class="log-entry status-${l.status}">
                <strong>[${l.timestamp}] Event: ${l.event}</strong> (${l.status_msg})<br>
                <small>Target: ${l.target}</small>
                <pre>${JSON.stringify(canonicalize(l.details), null, 2)}</pre>
            </div>
        `).join('');
    }

    setInterval(refreshLogs, 2000);
</script>
</body>
</html>
HTML
    }
);

