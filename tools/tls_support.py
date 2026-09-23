"""Verified administrative HTTPS connections; no local authentication bypass."""
import http.client
import json
import os
from pathlib import Path
import ssl
import stat
from urllib.parse import urlsplit


def private_directory(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('Security paths must be absolute and contain no .. components')
    for component in (path, *path.parents):
        info = component.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise ValueError(f'Symlink or non-directory in security path: {component}')
        if info.st_uid not in (0, os.getuid()) or (info.st_mode & 0o022 and not (info.st_uid == 0 and info.st_mode & stat.S_ISVTX)):
            raise ValueError(f'Unsafe ancestor of security file: {component}')
    info = path.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError(f'Require an owner-owned 0700 directory: {path}')
    return path


def private_path(path):
    path = Path(path)
    private_directory(path.parent)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
        raise ValueError(f'Require an owner-only regular file without symlinks: {path}')
    return path


def read_json(path):
    return json.loads(private_path(path).read_text())


def origin(value):
    parsed = urlsplit(value)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username is not None or
        parsed.password is not None or parsed.query or parsed.fragment or parsed.path not in ('', '/') or
        '?' in value or '#' in value or any(c.isspace() for c in value)):
        raise ValueError('relay_url must be an HTTPS origin, with no userinfo, query, fragment, or non-root path')
    if parsed.port == 0:
        raise ValueError('Invalid HTTPS port')
    return parsed


class Credentials:
    def __init__(self, path):
        cfg = read_json(path)
        if set(cfg) != {'relay_url', 'ca_file', 'client_cert_file', 'client_key_file'}:
            raise ValueError('Expected relay_url, ca_file, client_cert_file, client_key_file in administrative TLS config')
        self.endpoint = origin(cfg['relay_url'])
        if not ssl.HAS_TLSv1_3:
            raise RuntimeError('Python with OpenSSL and TLS 1.3 is required; Apple system Python is unsupported')
        for key in ('ca_file', 'client_cert_file', 'client_key_file'):
            private_path(cfg[key])
        # A new context has no default roots. Do not use create_default_context().
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        self.context.minimum_version = self.context.maximum_version = ssl.TLSVersion.TLSv1_3
        self.context.load_verify_locations(cafile=cfg['ca_file'])
        self.context.load_cert_chain(cfg['client_cert_file'], cfg['client_key_file'])
        self.context.set_alpn_protocols(['http/1.1'])

    def connection(self, timeout=20):
        return http.client.HTTPSConnection(self.endpoint.hostname, self.endpoint.port or 443,
                                          context=self.context, timeout=timeout)
