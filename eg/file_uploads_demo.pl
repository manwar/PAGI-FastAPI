#!/usr/bin/env perl

# Start the server
#
#   pagi-server file_uploads_demo.pl
#
# Then open http://localhost:5000/ for the interactive dashboard, or try
# these directly:
#
# 1. Single file + a text field
#
#   curl -F "caption=A lovely photo" -F "avatar=@/path/to/some/file.png" \
#        http://localhost:5000/profile/avatar
#
# 2. Multiple files under the same field name
#
#   curl -F "photos=@/path/to/one.jpg" -F "photos=@/path/to/two.jpg" \
#        http://localhost:5000/gallery
#

use v5.38;
use Future::AsyncAwait;
use PAGI::FastAPI;

my $app = PAGI::FastAPI->new(
    title   => 'PAGI::FastAPI File Uploads Demo',
    version => '1.7.0',
);

my $html_content = do { local $/; <DATA> };
$app->get('/',
    handler => async sub ($c) { $c->html($html_content); },
);

# Single file upload: $c->form_data / $c->uploaded_file
$app->post('/profile/avatar',
    tags        => ['Uploads'],
    summary     => 'Upload a profile avatar',
    description => 'Accepts a multipart/form-data body with a "caption" '
                  . 'text field and an "avatar" file part.',
    responses   => {
        422 => { description => 'No avatar file was provided' },
    },
    handler => async sub ($c) {
        my $caption = $c->form_data('caption') // '';
        my $avatar  = $c->uploaded_file('avatar');

        unless ($avatar) {
            $c->status(422);
            return { detail => "Missing 'avatar' file" };
        }

        return {
            caption      => $caption,
            filename     => $avatar->{filename},
            content_type => $avatar->{content_type},
            size         => $avatar->{size},
        };
    }
);

# Multiple files under one field name: $c->uploaded_files
$app->post('/gallery',
    tags        => ['Uploads'],
    summary     => 'Upload several photos at once',
    description => 'Accepts a multipart/form-data body with one or more '
                  . '"photos" file parts sharing the same field name.',
    handler => async sub ($c) {
        my $photos = $c->uploaded_files('photos');
        return {
            count     => scalar(@$photos),
            filenames => [ map { $_->{filename} } @$photos ],
        };
    }
);

$app->to_app;

__DATA__
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>PAGI::FastAPI File Uploads</title>
    <style>
        body { font-family: sans-serif; margin: 2em; max-width: 720px; }
        h2 { margin-bottom: 0.2em; }
        .sub { color: #666; margin-top: 0; }
        .card { border: 1px solid #ddd; border-radius: 8px; padding: 1.2em 1.5em; margin-bottom: 1.2em; }
        .row { display: flex; gap: 0.6em; align-items: center; margin-bottom: 0.8em; flex-wrap: wrap; }
        label { font-size: 0.9em; color: #444; }
        input[type="text"], input[type="file"] { padding: 6px; font-size: 1em; }
        button { padding: 8px 14px; font-size: 0.95em; cursor: pointer; }
        .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 0.8em; font-weight: bold; }
        .ok  { background: #e6f7e9; color: #1a7a34; }
        .bad { background: #fdeaea; color: #b3261e; }
        .result { margin-top: 0.6em; font-size: 0.9em; }
        ul { margin: 0.4em 0 0; padding-left: 1.2em; }
    </style>
</head>
<body>
    <h2>File Uploads</h2>
    <p class="sub">multipart/form-data, parsed via <code>$c-&gt;form_data</code> and <code>$c-&gt;uploaded_file(s)</code>.</p>

    <div class="card">
        <h3>Single file + a text field</h3>
        <p class="sub">POST /profile/avatar</p>
        <div class="row">
            <label for="caption">Caption:</label>
            <input type="text" id="caption" value="A lovely photo">
        </div>
        <div class="row">
            <input type="file" id="avatar">
            <button id="upload">Upload</button>
        </div>
        <div id="uploadResult" class="result"></div>
    </div>

    <div class="card">
        <h3>Multiple files, same field name</h3>
        <p class="sub">POST /gallery, select more than one file.</p>
        <div class="row">
            <input type="file" id="photos" multiple>
            <button id="uploadGallery">Upload gallery</button>
        </div>
        <div id="galleryResult" class="result"></div>
    </div>

    <script>
        document.getElementById('upload').onclick = async () => {
            const resultEl = document.getElementById('uploadResult');
            const fileInput = document.getElementById('avatar');
            if (!fileInput.files.length) {
                resultEl.innerHTML = '<span class="badge bad">no file selected</span>';
                return;
            }

            const form = new FormData();
            form.append('caption', document.getElementById('caption').value);
            form.append('avatar', fileInput.files[0]);

            const res = await fetch('/profile/avatar', { method: 'POST', body: form });
            const data = await res.json();

            resultEl.innerHTML = res.ok
                ? '<span class="badge ok">' + res.status + '</span> "' + data.caption
                    + '": ' + data.filename + ' (' + data.content_type + ', ' + data.size + ' bytes)'
                : '<span class="badge bad">' + res.status + '</span> ' + (data.detail || 'upload failed');
        };

        document.getElementById('uploadGallery').onclick = async () => {
            const resultEl = document.getElementById('galleryResult');
            const fileInput = document.getElementById('photos');
            if (!fileInput.files.length) {
                resultEl.innerHTML = '<span class="badge bad">no files selected</span>';
                return;
            }

            const form = new FormData();
            for (const file of fileInput.files) form.append('photos', file);

            const res = await fetch('/gallery', { method: 'POST', body: form });
            const data = await res.json();

            resultEl.innerHTML = res.ok
                ? '<span class="badge ok">' + res.status + '</span> ' + data.count + ' file(s): '
                    + '<ul>' + data.filenames.map(f => '<li>' + f + '</li>').join('') + '</ul>'
                : '<span class="badge bad">' + res.status + '</span> upload failed';
        };
    </script>
</body>
</html>
