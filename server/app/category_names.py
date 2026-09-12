def normalized_category_name(value: str) -> str:
    """Canonical comparison key for category names within one group."""
    return value.strip().casefold()
