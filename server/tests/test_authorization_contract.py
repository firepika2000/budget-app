import json
from pathlib import Path
from typing import get_args

from app.access import ALL_CAPABILITIES, LEGACY_CAPABILITIES
from app.schemas import CapabilityName


def test_server_capability_matrix_matches_shared_native_contract():
    rows = json.loads((Path(__file__).parent / "authorization_vectors" / "v1.json").read_text())
    assert set(rows) == {"view", "contribute", "manage", "owner"}
    assert set(rows["owner"]) == ALL_CAPABILITIES == set(get_args(CapabilityName))
    for permission, capabilities in LEGACY_CAPABILITIES.items():
        assert set(rows[permission]) == capabilities
        assert len(rows[permission]) == len(capabilities)
