"""One isolated run and report for the application, recovery, and content suites."""
from dataclasses import replace

from scenarios import Application, Desktop, History, Messages, Settings, SUITE
from recovery import Recovery
from content_scenarios import Content

SUITE = replace(SUITE, name="zimbr-all")
