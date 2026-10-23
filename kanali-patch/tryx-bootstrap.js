// tryx-kanali-linux: Wine workarounds for KANALI's main process, loaded before KANALI itself.
//
// `tryx-kanali run` copies this file to KANALI's resources/ folder as tryxboot.js and points
// the "main" entry of resources/app.asar/package.json at it (a same-length in-place edit,
// see asar-main.py). KANALI's original entry point is kept in tryxboot.json and loaded
// unchanged below.
'use strict';

const fs = require('fs');
const net = require('net');
const path = require('path');

// Wine bug: enabling TCP keep-alive on a socket *before* it has connected makes the connect
// fail with "connect UNKNOWN". axios (used by KANALI for every request from its main process:
// GIPHY downloads, TRYX cloud API, firmware checks, material library) does exactly that, so
// all of those requests failed and were reported as timeouts. Defer keep-alive until the
// socket is connected; behaviour is otherwise unchanged.
const origSetKeepAlive = net.Socket.prototype.setKeepAlive;
net.Socket.prototype.setKeepAlive = function (enable, initialDelay) {
  if (this.connecting || (!this._handle && !this.destroyed)) {
    this.once('connect', () => origSetKeepAlive.call(this, enable, initialDelay));
    return this;
  }
  return origSetKeepAlive.call(this, enable, initialDelay);
};

// Start KANALI from its original archive.
let main = './out/main/index.js';
try {
  main = JSON.parse(fs.readFileSync(path.join(__dirname, 'tryxboot.json'), 'utf8')).main || main;
} catch (e) { /* use the default */ }
require(path.join(__dirname, 'app.asar', main));
