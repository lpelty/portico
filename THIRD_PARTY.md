# Third-party software

Portico's app ships two pieces of other people's code, both under the MIT licence. Their licence text is also kept at the top of the shipped file.

## marked

`app/Sources/Portico/Resources/marked.min.js`: the Markdown renderer behind read mode. marked v15.0.12, Copyright (c) 2011-2025, Christopher Jeffrey. MIT licence: https://github.com/markedjs/marked/blob/master/LICENSE.md

## CodeMirror 6 and Lezer

`app/Sources/Portico/Resources/editor.js`: the editor (v0.20), bundled from `app/Editor/` by `app/Editor/build.sh`. Exact versions are pinned in `app/Editor/package.json` and `package-lock.json`; the bundle's header lists every package it contains.

- CodeMirror: `@codemirror/state`, `view`, `commands`, `language`, `autocomplete`, `lint`, `streamparser`, `legacy-modes`, `lang-markdown`, `lang-json`, `lang-yaml`, `lang-python`, `lang-javascript`, `lang-html`, `lang-css`.
- Lezer parsers: `@lezer/common`, `lr`, `highlight`, `markdown`, `json`, `yaml`, `python`, `javascript`, `html`, `css`.
- Their small helpers: `crelt`, `style-mod`, `w3c-keyname`, `@marijn/find-cluster-break`.

Development only, not shipped: `esbuild` (MIT) bundles the editor, and `jsdom` (MIT) runs its tests.

```
MIT License

Copyright (C) 2018-2021 by Marijn Haverbeke <marijn@haverbeke.berlin> and others

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```
