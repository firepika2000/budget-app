from collections import defaultdict, deque
from threading import Lock
from time import monotonic

from fastapi import HTTPException, Request, status


class AuthenticationRateLimiter:
    def __init__(self, attempts: int = 10, window_seconds: int = 300) -> None:
        self.attempts = attempts
        self.window_seconds = window_seconds
        self._failures: dict[str, deque[float]] = defaultdict(deque)
        self._lock = Lock()

    def key(self, request: Request, account_hint: str) -> str:
        client = request.client.host if request.client else "unknown"
        return f"{client}:{account_hint.strip().lower()}"

    def check(self, key: str) -> None:
        now = monotonic()
        with self._lock:
            failures = self._failures[key]
            self._prune(failures, now)
            if len(failures) >= self.attempts:
                retry_after = max(1, int(self.window_seconds - (now - failures[0])))
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail="Too many authentication attempts. Try again later.",
                    headers={"Retry-After": str(retry_after)},
                )

    def failed(self, key: str) -> None:
        now = monotonic()
        with self._lock:
            failures = self._failures[key]
            self._prune(failures, now)
            failures.append(now)

    def succeeded(self, key: str) -> None:
        with self._lock:
            self._failures.pop(key, None)

    def _prune(self, failures: deque[float], now: float) -> None:
        threshold = now - self.window_seconds
        while failures and failures[0] <= threshold:
            failures.popleft()
