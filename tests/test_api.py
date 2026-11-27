import importlib

import pytest
from fastapi.testclient import TestClient

JPEG = b"\xff\xd8\xff\xe0" + b"0" * 100


@pytest.fixture
def cliente(tmp_path, monkeypatch):
    monkeypatch.setenv("PELUCOS_DATOS", str(tmp_path))
    import app.main
    importlib.reload(app.main)
    return TestClient(app.main.app)


def test_pagina_y_puente(cliente):
    r = cliente.get("/")
    assert r.status_code == 200 and "Colección de pelucos" in r.text and "/servidor.js" in r.text
    assert cliente.get("/servidor.js").status_code == 200
    assert cliente.get("/salud").json() == {"ok": True}


def test_crear_listar_mezclar_y_borrar(cliente):
    assert cliente.get("/api/relojes").json() == []
    ficha = {"nombre": "Rolex", "ia": {"valor_min": 1, "valor_max": 2}, "tareas": [{"t": "a", "hecho": False}]}
    assert cliente.put("/api/relojes/rolex", json=ficha).status_code == 200
    assert cliente.get("/api/relojes").json() == [{**ficha, "id": "rolex"}]

    # update: los objetos se mezclan por dentro, las listas se sustituyen
    cliente.patch("/api/relojes/rolex", json={"excluirValor": True, "ia": {"valor_max": 3}, "tareas": []})
    r = cliente.get("/api/relojes").json()[0]
    assert r["excluirValor"] is True and r["ia"] == {"valor_min": 1, "valor_max": 3} and r["tareas"] == []

    assert cliente.patch("/api/relojes/otro", json={"a": 1}).status_code == 404
    assert cliente.delete("/api/relojes/rolex").status_code == 204
    assert cliente.get("/api/relojes").json() == []


def test_rechaza_ids_y_cuerpos_malos(cliente):
    assert cliente.put("/api/relojes/a..b", json={}).status_code == 400
    assert cliente.put("/api/relojes/x", content=b"[1]", headers={"Content-Type": "application/json"}).status_code == 400
    assert cliente.put("/api/relojes/x", content=b"no", headers={"Content-Type": "application/json"}).status_code == 400


def test_fotos(cliente, tmp_path):
    (tmp_path / "fotos").mkdir()
    (tmp_path / "fotos" / ("a" * 32)).write_bytes(JPEG)
    f = cliente.get("/_blob/" + "a" * 32)
    assert f.status_code == 200 and f.content == JPEG and f.headers["content-type"] == "image/jpeg"
    assert cliente.post("/api/fotos").status_code in (404, 405)  # no se suben fotos desde la web
    assert cliente.get("/_blob/" + "0" * 32).status_code == 404
    assert cliente.get("/_blob/..%2Fpelucos.db").status_code == 404
