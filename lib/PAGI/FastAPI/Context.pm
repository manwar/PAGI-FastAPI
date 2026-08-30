package PAGI::FastAPI::Context;

use v5.38;
use experimental 'class';
use version;

our $VERSION   = qv('v1.7.1');
our $AUTHORITY = 'cpan:MANWAR';

class PAGI::FastAPI::Context {
    use Future::IO;
    use Scalar::Util ();
    use PAGI::FastAPI::Response::File qw(file_response);

    field $scope                :param = {};
    field $query_params         :param = {};
    field $path_params          :param = {};
    field $body                 :param = undef;
    field $form_data            :param = undef;
    field $uploaded_files       :param = {};
    field $status               :param = 200;
    field $res_headers          :param = [];
    field $stash                :param = {};
    field $pagi_context         :param = undef;
    field $background_registrar :param = undef;

    method scope { $scope }

    method sleep ($seconds) {
        return Future::IO->sleep($seconds);
    }

    method status ($val = undef) {
        if (defined $val) {
            $status = $val;
        }
        return $status;
    }

    method pagi_context { $pagi_context }

    method csrf_token () {
        # 1. Direct scope environment
        if (defined $scope
            && ref $scope eq 'HASH'
            && $scope->{'pagi.csrf_token'}) {
            return $scope->{'pagi.csrf_token'};
        }

        # 2. PAGI context environment
        if (defined $pagi_context
            && $pagi_context->can('env')) {
            my $env = $pagi_context->env;
            return $env->{'pagi.csrf_token'}
                if $env && $env->{'pagi.csrf_token'};
        }

        # 3. Session storage fallback
        if (defined $scope
            && $scope->{'pagi.session'}
            && ref $scope->{'pagi.session'} eq 'HASH') {
            return $scope->{'pagi.session'}{'csrf_token'};
        }

        return undef;
    }

    method csrf_verify ($token) {
        die "PAGI context is not set" unless defined $pagi_context;
        return $pagi_context->csrf_verify($token);
    }

    method res_headers { $res_headers }

    method set_header ($key, $val) {
        my $lc_key = lc($key);
        for my $h (@$res_headers) {
            if (lc($h->[0]) eq $lc_key) {
                $h->[0] = $key;
                $h->[1] = $val;
                return;
            }
        }
        push @$res_headers, [$key, $val];
    }

    method add_header ($key, $val) {
        push @$res_headers, [$key, $val];
    }

    method header ($name) {
        my $headers = $scope->{headers} // [];
        my $lc_name = lc($name);
        for my $h (@$headers) {
            return $h->[1] if lc($h->[0]) eq $lc_name;
        }
        return undef;
    }

    method file ($filepath, %opts) {
        # For static assets served directly (like CSS/JS),
        # set as_attachment => 0 by default unless explicitly overridden.
        $opts{as_attachment} //= 0;

        return file_response($filepath, %opts);
    }

    method html ($content, %opts) {
        use PAGI::FastAPI::Response::HTML;

        return PAGI::FastAPI::Response::HTML->new(
            body    => $content,
            headers => $opts{headers} // [],
            status  => $opts{status}  // 200,
        );
    }

    method sse ($code) {
        use PAGI::FastAPI::Response::SSE;

        return PAGI::FastAPI::Response::SSE->new(
            generator => $code,
        );
    }

    method path_params  { $path_params }
    method query_params { $query_params }

    method path_param ($name) {
        return $path_params->{$name};
    }

    method query_param ($name) {
        return $query_params->{$name};
    }

    method body ($key = undef) {
        if (defined $key) {
            return (ref $body eq 'HASH') ? $body->{$key} : undef;
        }
        return $body;
    }

    method form_data ($key = undef) {
        if (defined $key) {
            return (ref $form_data eq 'HASH') ? $form_data->{$key} : undef;
        }
        return $form_data;
    }

    method uploaded_files ($name = undef) {
        if (defined $name) {
            return $uploaded_files->{$name} // [];
        }
        return $uploaded_files;
    }

    method uploaded_file ($name) {
        my $files = $uploaded_files->{$name} // [];
        return $files->[0];
    }

    method background ($code) {
        die "background() expects a CODE reference (e.g. an async sub)\n"
            unless ref $code eq 'CODE';

        my $future = $code->();

        die "background() callback did not return a Future, did you "
          . "forget 'async' before 'sub'?\n"
            unless Scalar::Util::blessed($future) && $future->isa('Future');

        return $background_registrar ? $background_registrar->($future) : $future;
    }

    method param ($key) {
        return $self->path_param($key)
            // $self->query_param($key)
            // $self->body($key);
    }

    method stash { $stash }
}

=encoding utf-8

=head1 NAME

PAGI::FastAPI::Context - Request and Response Lifecycle Context for PAGI::FastAPI

=head1 VERSION

Version v1.7.1

=head1 SYNOPSIS

    # Inspecting Request Parameters
    my $user_id = $c->path_param('id');
    my $limit   = $c->query_param('limit');
    my $name    = $c->body('name');

    # Generic Parameter Fallback (Path -> Query -> Body)
    my $token   = $c->param('token');

    # Headers & Scope
    my $ua      = $c->header('User-Agent');
    my $scope   = $c->scope;

    # Stash Storage
    $c->stash->{user} = { id => 42, role => 'admin' };

    # Modifying Response State
    $c->status(201);
    $c->set_header('X-Custom-Header' => 'value');

=head1 DESCRIPTION

C<PAGI::FastAPI::Context> encapsulates the request environment, parsed parameters,
payload data, and response state for an individual HTTP exchange processed
by L<PAGI::FastAPI>.

An instance of this context is passed as the primary argument to route handlers,
middleware functions, and dependency blocks.

=head1 METHODS

=head2 C<new(%args)>

Constructor called internally by L<PAGI::FastAPI>. Accepts named arguments:

=over 4

=item * C<scope> - PAGI environment HashRef.

=item * C<query_params> - HashRef of validated query parameters.

=item * C<path_params> - HashRef of route path variables.

=item * C<body> - Decoded payload body (HashRef, ArrayRef, or Scalar).

=item * C<form_data> - HashRef of parsed form fields, for a request whose
body was C<application/x-www-form-urlencoded> or C<multipart/form-data>.
C<undef> for a JSON body.

=item * C<uploaded_files> - HashRef of uploaded file parts from a
C<multipart/form-data> body, keyed by field name.

=item * C<status> - Initial HTTP response code (default: C<200>).

=item * C<res_headers> - Initial response headers ArrayRef (default: C<[]>).

=item * C<stash> - Context-bound storage HashRef (default: C<{}>).

=back

=head2 C<scope()>

Returns the raw PAGI scope HashRef for the current request.

=head2 C<sleep($seconds)>

    await $c->sleep(1);

Asynchronously pauses execution for the given number of seconds without blocking the event loop.

Uses L<Future::IO> under the hood to ensure non-blocking sleep operations.

=over 4

=item * C<$seconds>

Number of seconds to sleep (fractional seconds like C<0.5> are supported).

=back

Returns a L<Future> that completes when the specified sleep duration has elapsed.

=head2 C<status([ $code ])>

Gets or sets the HTTP status code for the response.

    $c->status(403);
    my $code = $c->status; # 403

=head2 C<pagi_context>

    my $pagi_ctx = $c->pagi_context;

Returns the underlying low-level L<PAGI::Context> instance associated with
the current HTTP request. Useful for low-level protocol inspection, raw
environment access, or invoking protocol-specific extension methods.

=head2 C<csrf_token>

    my $token = $c->csrf_token;

Retrieves the active Anti-CSRF token for the current request.

This method transparently attempts to resolve the token from three potential
locations in order of precedence:

=over 4

=item 1. B<Direct Scope Environment:> C<< $scope->{'pagi.csrf_token'} >> (set directly by L<PAGI::Middleware::CSRF>).

=item 2. B<PAGI Context Environment:> C<< $pagi_context->env->{'pagi.csrf_token'} >>.

=item 3. B<Session Storage Fallback:> C<< $scope->{'pagi.session'}{'csrf_token'} >> (set by session management middleware).

=back

Returns the scalar token string if found, or C<undef> if no token is
available or if CSRF/Session middleware is not active for the request.

B<Example Usage (Embedding in HTML forms):>

    $app->get('/form', handler => async sub ($c) {
        my $token = $c->csrf_token // '';
        return $c->html(qq{
            <form method="POST" action="/submit">
                <input type="hidden" name="csrf_token" value="$token">
                <button type="submit">Submit</button>
            </form>
        });
    });

=head2 C<csrf_verify($token)>

    my $is_valid = $c->csrf_verify($submitted_token);

Explicitly validates the given C<$token> against the current request's CSRF
state by delegating to the underlying low-level L<PAGI::Context> instance.

Accepts a scalar token string C<$token>. Returns a true value if the token
signature and expiration are valid; returns false otherwise.

Dies with C<"PAGI context is not set"> if invoked when no low-level
L<PAGI::Context> instance is associated with C<$c>.

B<Example Usage (Manual Verification):>

    $app->post('/api/action', handler => async sub ($c) {
        my $token = $c->body('csrf_token');

        unless ($c->csrf_verify($token)) {
            $c->status(403);
            return { error => 'Invalid or missing CSRF token' };
        }

        return { status => 'success' };
    });

=head2 C<res_headers()>

Returns the current list of outgoing response header pairs as an ArrayRef of
tuple pairs C<[ [$name, $val], ... ]>.

=head2 C<set_header($key, $val)>

Sets an outgoing HTTP header, case-insensitively replacing any existing
header of the same name (last write wins). Use this for headers that
should only ever have one value.

    $c->set_header('X-Frame-Options' => 'DENY');
    $c->set_header('Content-Type'    => 'text/plain'); # replaces any prior Content-Type

=head2 C<add_header($key, $val)>

Appends an additional outgoing HTTP header pair without touching any
existing header of the same name. Use this only for headers that are
legitimately allowed to appear more than once (e.g. C<Set-Cookie>,
C<Vary>, C<Link>); for everything else prefer C<set_header>.

    $c->add_header('Set-Cookie' => 'session=abc123; Path=/');
    $c->add_header('Set-Cookie' => 'theme=dark; Path=/');

=head2 C<header($name)>

Case-insensitively searches incoming request headers (from C<< $c->scope->{headers} >>)
and returns its scalar value, or C<undef> if missing.

    my $auth = $c->header('Authorization');

=head2 C<file($filepath, %options)>

    $app->get('/assets/app.js', handler => async sub ($c) {
        return $c->file('/var/www/static/app.js');
    });

    $app->get('/reports/annual.pdf', handler => async sub ($c) {
        return $c->file(
            '/var/www/reports/2026.pdf',
            as_attachment => 1,
            filename      => 'annual-report-2026.pdf',
        );
    });

Constructs and returns a L<PAGI::FastAPI::Response::File> instance to stream a
file from disk to the client.

Delegates directly to L<PAGI::FastAPI::Response::File/file_response>, with a
context-aware default of C<as_attachment =E<gt> 0> to ensure assets (such as CSS,
JavaScript, or images) display inline in the browser rather than triggering a
download prompt.

Accepts the following named options:

=over 4

=item * C<as_attachment> (Boolean, optional)

Controls the C<Content-Disposition> response header. Defaults to C<0> (inline)
when called via C<< $c->file >>. Set to C<1> to force the browser to download
the file as an attachment.

=item * C<content_type> (String, optional)

Explicitly overrides the MIME type sent in the C<Content-Type> header. When
omitted, the content type is guessed automatically from the file extension of
C<$filepath>.

=item * C<filename> (String, optional)

Sets a custom filename string for the C<Content-Disposition> header. Useful when
serving files stored under internal hashes or non-descriptive paths on disk.

=item * C<status> (Integer, optional)

The HTTP status code to return with the file response. Defaults to C<200>.

=back

Returns an instance of L<PAGI::FastAPI::Response::File>.

=head2 C<html($content, %options)>

    $app->get('/about', handler => async sub ($c) {
        return $c->html('<h1>About Us</h1>');
    });

Returns an HTTP response with the C<Content-Type> header automatically set to C<text/html; charset=utf-8>.

Accepts the HTML content string as the first parameter, followed by optional named parameters:

=over 4

=item * C<status> (Optional)

Integer HTTP status code. Defaults to C<200>.

=item * C<headers> (Optional)

ArrayRef of additional header key-value pairs.

=back

Returns a C<PAGI::FastAPI::Response> object.

=head2 C<sse($code)>

    $app->get('/api/v1/metrics', handler => async sub ($c) {
        return $c->sse(async sub ($stream) {
            while (1) {
                await $stream->send_json({ cpu => 42 });
                await $c->sleep(1);
            }
        });
    });

Creates and returns a Server-Sent Events (SSE) response object.

Accepts an async generator coderef that receives an SSE stream handler as
its first argument.

=over 4

=item * C<$code>

An C<async sub> coderef that defines the event streaming loop. The callback
receives an instance of L<PAGI::SSE>, offering methods such as
C<send_event()>, C<send_json()>, C<send()>, C<keepalive()>, and C<close()>.

=back

Returns an instance of L<PAGI::FastAPI::Response::SSE>.

=head2 C<path_params()>

Returns the HashRef containing all parsed path parameters.

=head2 C<path_param($key)>

Returns a specific parsed path parameter by name, or C<undef> if absent.

=head2 C<query_params()>

Returns the HashRef containing all parsed query parameters.

=head2 C<query_param($key)>

Returns a specific parsed query parameter by name, or C<undef> if absent.

=head2 C<body([ $key ])>

If called without parameters, returns the full raw/decoded request body.

If called with a C<$key> parameter and the body is a HashRef, returns the
value for that key, or C<undef> if missing or if the body is not a HashRef.

    my $full_body = $c->body;
    my $user_name = $c->body('username');

=head2 C<form_data([ $key ])>

    $app->post('/upload', handler => async sub ($c) {
        my $caption = $c->form_data('caption');
        ...
    });

Returns the parsed form fields for a request body that was either
C<application/x-www-form-urlencoded> or C<multipart/form-data>, with the
same calling convention as C<body>: no arguments returns the full HashRef,
a C<$key> argument returns that one field's value (or C<undef>).

For a C<multipart/form-data> body, this returns only the plain text
fields, file parts are available separately via C<uploaded_files>.
C<undef> for a JSON body (JSON is not a form).

Note that for both C<application/x-www-form-urlencoded> and
C<multipart/form-data> bodies, C<body> and C<form_data> return the I<same>
HashRef, C<form_data> exists as a clearer-named alias for form-sourced
data specifically, not as a separate parse.

=head2 C<uploaded_files([ $field_name ])>

    my $all_files   = $c->uploaded_files;           # HashRef, keyed by field name
    my $avatar_list = $c->uploaded_files('avatar'); # ArrayRef for one field

Returns uploaded file parts from a C<multipart/form-data> request body.

With no arguments, returns a HashRef keyed by field name. With a
C<$field_name> argument, returns just that field's files (or an empty
ArrayRef if none were uploaded under that name).

Each file is always represented as an ArrayRef of HashRefs, even when only
one file was uploaded for that field, so a single-file C<< <input
type="file"> >> and a multi-file C<< <input type="file" multiple> >> have
the same shape to consume. Each file HashRef has:

=over 4

=item * C<filename> - The original filename supplied by the client.

=item * C<content_type> - The C<Content-Type> declared for that part, or
C<application/octet-stream> if none was given.

=item * C<content> - The raw file bytes.

=item * C<size> - Byte length of C<content>.

=back

B<Note:> file contents are currently held fully in memory for the
duration of the request; there is no streaming or on-disk spooling for
large uploads.

=head2 C<uploaded_file($field_name)>

    my $avatar = $c->uploaded_file('avatar');
    if ($avatar) {
        say "Got $avatar->{filename}, $avatar->{size} bytes";
    }

Convenience accessor for the common single-file-per-field case. Returns
the I<first> uploaded file HashRef for C<$field_name> (see
C<uploaded_files> above for its shape), or C<undef> if no file was
uploaded under that name.

=head2 C<param($key)>

Convenience parameter accessor that checks parameter stores in priority order:

1. Path parameters (C<path_param>)
2. Query parameters (C<query_param>)
3. JSON/Body fields (C<body($key)>)

Returns the first matching non-undef value, or C<undef> if the key is not
present in any store.

=head2 C<stash()>

Returns a HashRef tied to the lifecycle of this context. Useful for sharing
data between middleware, dependency injection blocks, and final route
handlers.

    $c->stash->{db_session} = $db;

=head2 C<background($code)>

    $app->post('/signup', handler => async sub ($c) {
        my $email = $c->body('email');

        $c->background(async sub {
            await send_welcome_email($email);   # runs after the response is sent
        });

        return { status => 'account created' };
    });

Schedules an C<async sub> to keep running I<after> the response has
already been sent, without making the caller wait for it, for
fire-and-forget work like sending an email, writing an audit log entry, or
warming a cache.

C<$code> must be an C<async sub> (or any coderef that, when called with no
arguments, returns a L<Future>); C<background> calls it immediately and
retains the resulting Future for you, so it won't be garbage-collected or
silently dropped before it completes, the same way the framework already
owns the request/response lifecycle. A task that dies is logged (via
C<warn>) rather than crashing the request that scheduled it, or any other
in-flight request.

Retention is owned by the application, not the request: scheduled tasks
outlive the C<$c> that scheduled them, and any still-pending tasks are
awaited during PAGI Lifespan C<shutdown> (before your own C<on_shutdown>
callbacks run), so a task doesn't get killed mid-flight by process exit
under normal shutdown.

Dies immediately, before scheduling anything, if C<$code> isn't a coderef,
or if calling it didn't return a L<Future> (the most common cause of the
latter: forgetting the C<async> keyword).

=head1 AUTHOR

Mohammad Sajid Anwar, C<< <mohammad.anwar at yahoo.com> >>

=head1 REPOSITORY

L<https://github.com/manwar/PAGI-FastAPI>

=head1 BUGS

Please report any bugs or feature requests through the web interface at L<https://github.com/manwar/PAGI-FastAPI/issues>.
I will be notified and then you'll automatically be notified of progress on your
bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc PAGI::FastAPI::Context

You can also look for information at:

=over 4

=item * BUG Report

L<https://github.com/manwar/PAGI-FastAPI/issues>

=item * Search MetaCPAN

L<https://metacpan.org/dist/PAGI-FastAPI/>

=back

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2026 Mohammad Sajid Anwar.

This program is free software; you can redistribute it and/or modify it under
the terms of the Artistic License (2.0).

=cut

1; # End of PAGI::FastAPI::Context
