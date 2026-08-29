#!/usr/bin/env perl

# Start the server
#
#   pagi-server background_demo.pl
#
# Then open http://localhost:5000/ for the interactive dashboard, or try
# these directly:
#
#   curl -X POST http://localhost:5000/signup \
#        -H "Content-Type: application/json" \
#        -d '{"email": "alice@example.com"}'
#   curl http://localhost:5000/activity-log
#
# Notice the POST returns immediately (status 202) while the entry in
# /activity-log stays "queued" for a couple of seconds before flipping to
# "done" on its own, that's $c->background() running after the response
# was already sent.
#

use v5.38;
use Future::AsyncAwait;
use Types::Standard qw(Str);
use PAGI::FastAPI;

my $app = PAGI::FastAPI->new(
    title   => 'PAGI::FastAPI Background Tasks Demo',
    version => '1.3.0',
);

# A tiny in-memory activity log so the dashboard can actually *see* a
# background task go from "queued" to "done" a couple of seconds later,
# fire-and-forget work has no response of its own to show that in.
# Demo-only: a real app would write this to a DB, a queue, wherever the
# task's own result belongs, not to a package-level ArrayRef.
my @activity_log;

my $html_content = do { local $/; <DATA> };
$app->get('/',
    handler => async sub ($c) { $c->html($html_content); },
);

$app->post('/signup',
    tags        => ['Onboarding'],
    summary     => 'Create an account',
    description => 'Responds immediately; the welcome email is sent '
                  . 'afterward via a background task and shows up in '
                  . 'GET /activity-log once it completes.',
    body        => { email => Str },
    responses   => {
        202 => { description => 'Account created, welcome email queued' },
    },
    handler => async sub ($c) {
        my $email = $c->body('email');
        my $entry = { email => $email, status => 'queued' };
        push @activity_log, $entry;

        $c->background(async sub {
            # Simulated slow work (an SMTP call, a templating step, ...).
            # A real handler would await that call directly instead of
            # $c->sleep, this is here purely so the demo's "queued" ->
            # "done" transition is visible for a couple of seconds.
            await $c->sleep(2);
            $entry->{status} = 'done';
        });

        $c->status(202);
        return { status => 'queued', email => $email };
    }
);

$app->get('/activity-log',
    tags        => ['Onboarding'],
    summary     => 'List queued/completed welcome emails',
    description => 'Demo-only introspection endpoint backed by an '
                  . 'in-memory array, so the dashboard can show a '
                  . 'background task finishing after its request '
                  . 'already returned.',
    handler => async sub ($c) {
        return { entries => \@activity_log };
    }
);

$app->to_app;

__DATA__
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>PAGI::FastAPI Background Tasks</title>
    <style>
        body { font-family: sans-serif; margin: 2em; max-width: 720px; }
        h2 { margin-bottom: 0.2em; }
        .sub { color: #666; margin-top: 0; }
        .card { border: 1px solid #ddd; border-radius: 8px; padding: 1.2em 1.5em; margin-bottom: 1.2em; }
        .row { display: flex; gap: 0.6em; align-items: center; margin-bottom: 0.8em; flex-wrap: wrap; }
        label { font-size: 0.9em; color: #444; }
        input[type="email"] { padding: 6px; font-size: 1em; }
        button { padding: 8px 14px; font-size: 0.95em; cursor: pointer; }
        .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 0.8em; font-weight: bold; }
        .ok      { background: #e6f7e9; color: #1a7a34; }
        .pending { background: #fff6dd; color: #916b00; }
        #log { border: 1px solid #ddd; border-radius: 8px; height: 200px; overflow-y: scroll; padding: 10px; font-family: monospace; font-size: 0.85em; }
        .entry { margin-bottom: 4px; white-space: pre-wrap; }
        .empty { color: #999; font-style: italic; }
    </style>
</head>
<body>
    <h2>Background Tasks</h2>
    <p class="sub">POST /signup returns immediately; the welcome-email task keeps running via <code>$c-&gt;background()</code> and shows up below a couple of seconds later.</p>

    <div class="card">
        <div class="row">
            <label for="email">Email:</label>
            <input type="email" id="email" value="alice@example.com">
            <button id="signup">Sign Up</button>
        </div>
        <h4>Activity Log</h4>
        <div id="log"><div class="empty">Nothing queued yet...</div></div>
    </div>

    <script>
        const logEl = document.getElementById('log');

        function renderLog(entries) {
            if (!entries.length) {
                logEl.innerHTML = '<div class="empty">Nothing queued yet...</div>';
                return;
            }
            logEl.innerHTML = entries.map(e => {
                const badge = e.status === 'done'
                    ? '<span class="badge ok">done</span>'
                    : '<span class="badge pending">queued</span>';
                return '<div class="entry">' + badge + ' welcome email for ' + e.email + '</div>';
            }).reverse().join('');
        }

        async function refreshLog() {
            const res = await fetch('/activity-log');
            const data = await res.json();
            renderLog(data.entries);
        }

        document.getElementById('signup').onclick = async () => {
            const email = document.getElementById('email').value;
            await fetch('/signup', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ email }),
            });
            await refreshLog();
        };

        refreshLog();
        setInterval(refreshLog, 1000);
    </script>
</body>
</html>
