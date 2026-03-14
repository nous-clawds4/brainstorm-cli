/**
 * HTTP client wrapper for the Brainstorm API.
 * Handles base URL, auth headers, and JSON parsing.
 */

import { getServerUrl, getToken } from './config.js';

export class BrainstormClient {
  constructor(serverUrl, token) {
    this.serverUrl = serverUrl || getServerUrl();
    this.token = token || getToken();
  }

  async request(method, path, { body, query, auth = false } = {}) {
    let url = `${this.serverUrl}${path}`;

    if (query) {
      const params = new URLSearchParams();
      for (const [k, v] of Object.entries(query)) {
        if (v !== undefined && v !== null) params.append(k, String(v));
      }
      const qs = params.toString();
      if (qs) url += `?${qs}`;
    }

    const headers = { 'Content-Type': 'application/json' };
    if (auth && this.token) {
      headers['Authorization'] = `Bearer ${this.token}`;
    }

    const opts = { method, headers };
    if (body) {
      opts.body = JSON.stringify(body);
    }

    const res = await fetch(url, opts);
    const text = await res.text();

    let data;
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }

    if (!res.ok) {
      const msg = data?.detail || data?.message || `HTTP ${res.status}`;
      throw new Error(msg);
    }

    return data;
  }

  // Convenience methods
  async get(path, opts = {}) {
    return this.request('GET', path, opts);
  }

  async post(path, opts = {}) {
    return this.request('POST', path, opts);
  }
}

// Singleton for CLI commands
let _client;
export function getClient() {
  if (!_client) _client = new BrainstormClient();
  return _client;
}
