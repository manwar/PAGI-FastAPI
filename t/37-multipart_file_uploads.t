#!/usr/bin/env perl

use v5.38;
use Test::More;

use PAGI::FastAPI;
use Future::AsyncAwait;
use JSON::PP qw(decode_json);

sub run_request ($pagi_app, %req) {
    my $recv = async sub { return { type => 'http.request', body => $req{body}, more_body => 0 } };

    my ($sent_start, $sent_body);
    my $send = async sub ($event) {
        $sent_start = $event if $event->{type} eq 'http.response.start';
        $sent_body  = $event if $event->{type} eq 'http.response.body';
    };

    $pagi_app->(
        {
            type         => 'http',
            method       => $req{method} // 'POST',
            path         => $req{path},
            query_string => '',
            headers      => $req{content_type} ? [['content-type', $req{content_type}]] : [],
        },
        $recv, $send,
    )->get;

    my $decoded = $sent_body->{body} && length $sent_body->{body}
    ? eval { decode_json($sent_body->{body}) }
    : undef;

    return ($sent_start->{status}, $decoded);
}

my $app = PAGI::FastAPI->new(title => 'PAGI::FastAPI Multipart File Uploads');

$app->post('/upload',
    handler => async sub ($c) {
        my $avatar = $c->uploaded_file('avatar');
        return {
            caption      => $c->form_data('caption'),
            has_avatar   => $avatar ? 1 : 0,
            filename     => $avatar ? $avatar->{filename}     : undef,
            content_type => $avatar ? $avatar->{content_type} : undef,
            size         => $avatar ? $avatar->{size}         : undef,
            content      => $avatar ? $avatar->{content}      : undef,
            # $c->body should behave identically to $c->form_data for multipart,
            # same as it already does for application/x-www-form-urlencoded
            body_caption => $c->body('caption'),
        };
    }
);

$app->post('/gallery',
    handler => async sub ($c) {
        my $photos = $c->uploaded_files('photos');
        return {
            count     => scalar(@$photos),
            filenames => [ map { $_->{filename} } @$photos ],
        };
    }
);

my $pagi_app = $app->to_app;

my $boundary = '----TestBoundary123';

subtest 'a multipart body with a text field and a file upload is parsed correctly' => sub {
    my $body = join "\r\n",
        "--$boundary",
        'Content-Disposition: form-data; name="caption"',
        '',
        'A lovely photo',
        "--$boundary",
        'Content-Disposition: form-data; name="avatar"; filename="cat.png"',
        'Content-Type: image/png',
        '',
        "FAKE-PNG-BYTES",
        "--$boundary--",
        '';

    my ($status, $data) = run_request($pagi_app,
        path => '/upload',
        content_type => "multipart/form-data; boundary=$boundary",
        body => $body,
    );

    is $status, 200, 'multipart POST no longer hard-fails with 422 (the core bug)';
    is $data->{caption}, 'A lovely photo', 'plain text field is available via form_data()';
    is $data->{body_caption}, 'A lovely photo', '$c->body() also works for multipart, same as urlencoded';
    is $data->{has_avatar}, 1, 'file part detected';
    is $data->{filename}, 'cat.png', 'filename extracted from Content-Disposition';
    is $data->{content_type}, 'image/png', "file part's own Content-Type captured";
    is $data->{content}, 'FAKE-PNG-BYTES', 'raw file bytes reach the handler untouched';
    is $data->{size}, length('FAKE-PNG-BYTES'), 'size matches the byte length of content';
};

subtest 'multiple files under the same field name all arrive as an ArrayRef' => sub {
    my $body = join "\r\n",
        "--$boundary",
        'Content-Disposition: form-data; name="photos"; filename="one.jpg"',
        'Content-Type: image/jpeg',
        '',
        'AAA',
        "--$boundary",
        'Content-Disposition: form-data; name="photos"; filename="two.jpg"',
        'Content-Type: image/jpeg',
        '',
        'BBB',
        "--$boundary--",
        '';

    my ($status, $data) = run_request($pagi_app,
        path => '/gallery',
        content_type => "multipart/form-data; boundary=$boundary",
        body => $body,
    );

    is $status, 200, 'multi-file upload succeeds';
    is $data->{count}, 2, 'both files under the same field name are captured';
    is_deeply $data->{filenames}, ['one.jpg', 'two.jpg'], 'both filenames present, in order';
};

subtest 'a quoted boundary in the Content-Type header still parses' => sub {
    my $body = join "\r\n",
        "--$boundary",
        'Content-Disposition: form-data; name="caption"',
        '',
        'quoted boundary test',
        "--$boundary--",
        '';

    my ($status, $data) = run_request($pagi_app,
        path => '/upload',
        content_type => qq{multipart/form-data; boundary="$boundary"},
        body => $body,
    );

    is $status, 200, 'quoted boundary value is accepted';
    is $data->{caption}, 'quoted boundary test', 'field still extracted correctly';
};

subtest 'a request with no file part just has an empty uploaded_files list' => sub {
    my $body = join "\r\n",
        "--$boundary",
        'Content-Disposition: form-data; name="caption"',
        '',
        'no file here',
        "--$boundary--",
        '';

    my ($status, $data) = run_request($pagi_app,
        path => '/upload',
        content_type => "multipart/form-data; boundary=$boundary",
        body => $body,
    );

    is $status, 200, 'still succeeds with no file part present';
    is $data->{has_avatar}, 0, 'uploaded_file() returns undef when the field is absent';
};

subtest 'JSON and urlencoded bodies are completely unaffected (backward compatibility)' => sub {
    my ($status, $data) = run_request($pagi_app,
        path => '/upload', content_type => 'application/json',
        body => '{"caption":"json still works"}',
    );
    is $status, 200, 'JSON body still handled normally';
    is $data->{body_caption}, 'json still works', 'JSON field still reachable via $c->body() as before';
    is $data->{caption}, undef, '$c->form_data() correctly stays undef for a JSON body (JSON is not a form)';
};

done_testing;
