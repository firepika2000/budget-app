def test_admin_shell_has_security_headers_and_local_assets(client):
    response = client.get("/admin")
    assert response.status_code == 200
    assert "default-src 'self'" in response.headers["content-security-policy"]
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["referrer-policy"] == "no-referrer"
    assert '<script src="/admin-assets/app.js"' in response.text
    assert '<link rel="stylesheet" href="/admin-assets/styles.css"' in response.text
    assert 'id="export-button"' in response.text
    assert 'id="move-money-button"' in response.text
    assert "https://" not in response.text


def test_admin_assets_are_served_without_exposing_html_entrypoint(client):
    assert client.get("/admin-assets/app.js").status_code == 200
    assert client.get("/admin-assets/styles.css").status_code == 200
    assert client.get("/admin-assets/favicon.svg").status_code == 200
    assert client.get("/admin-assets/index.html").status_code == 404
