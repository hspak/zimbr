class ZrctError(Exception):
    category = "infrastructure_failure"

    def __init__(self, message, **details):
        super().__init__(message)
        self.details = details


class ExpectationFailed(ZrctError, AssertionError):
    category = "assertion_failure"


class MissingTarget(ExpectationFailed):
    """A locator currently has no match; eventual expectations may retry it."""


class AppCrashed(ZrctError):
    category = "application_crash"


class Unsupported(ZrctError):
    category = "unsupported_capability"


class DeadlineExceeded(ZrctError):
    category = "timeout"


class ProtocolError(ZrctError):
    category = "protocol_error"
