"""Relay identities shared with the Zig build and native runtime."""
from dataclasses import dataclass
import json
from pathlib import Path
import subprocess


@dataclass(frozen=True)
class Profile:
    name: str
    display_name: str
    bundle_id: str
    data_directory: str
    command: str
    default_port: int

    @property
    def app_name(self):
        return self.display_name + '.app'

    def app(self, home):
        return home / 'Applications' / self.app_name

    def data(self, home):
        return home / 'Library/Application Support' / self.data_directory

    def verify_binary(self, binary):
        actual = json.loads(subprocess.check_output([str(binary), 'profile'], text=True))
        if actual != self.__dict__:
            raise ValueError(f'Relay binary does not match the {self.name} profile; rebuild with -Dprofile={self.name}')


PROFILES = {name: Profile(**fields) for name, fields in
            json.loads(Path(__file__).with_name('profiles.json').read_text()).items()}
