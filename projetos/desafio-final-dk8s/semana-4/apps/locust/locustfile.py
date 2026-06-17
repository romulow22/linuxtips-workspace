"""
Locust - stress test do TipsBank.
Simula usuarios criando contas e fazendo transferencias.

Execucao local:
    locust -f locustfile.py --host http://localhost:8082

Execucao em Kubernetes:
    --host aponta para api-transacoes; on_start chama api-contas via urllib.
"""
import json
import random
import uuid
import urllib.request
from locust import HttpUser, task, between, events

CONTAS_URL = "http://api-contas.tipsbank-contas.svc.cluster.local:8080"

CONTAS_CRIADAS: list[str] = []


class UsuarioBanco(HttpUser):
    wait_time = between(0.5, 2)

    def on_start(self):
        documento = "".join(random.choices("0123456789", k=11))
        payload = {
            "titular": f"Aluno {uuid.uuid4().hex[:6]}",
            "documento": documento,
            "saldo_inicial": "999999999.00",
            "senha": "locust123",
        }
        try:
            req = urllib.request.Request(
                f"{CONTAS_URL}/contas",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5) as r:
                if r.status == 201:
                    CONTAS_CRIADAS.append(json.loads(r.read())["id"])
        except Exception:
            pass

    @task(3)
    def transferir(self):
        if len(CONTAS_CRIADAS) < 2:
            return
        origem, destino = random.sample(CONTAS_CRIADAS, 2)
        valor = round(random.uniform(0.01, 1.00), 2)
        try:
            with self.client.post(
                "/transferencias",
                json={"origem_id": origem, "destino_id": destino, "valor": str(valor)},
                name="/transferencias",
                catch_response=True,
            ) as r:
                if r.status_code >= 500:
                    r.failure(f"5xx: {r.status_code}")
                else:
                    r.success()
        except Exception:
            pass

    @task(1)
    def consultar_extrato(self):
        if not CONTAS_CRIADAS:
            return
        conta = random.choice(CONTAS_CRIADAS)
        try:
            with self.client.get(
                f"/extrato/{conta}",
                name="/extrato/:id",
                catch_response=True,
            ) as r:
                if r.status_code >= 500:
                    r.failure(f"5xx: {r.status_code}")
                else:
                    r.success()
        except Exception:
            pass


@events.test_stop.add_listener
def resumo(environment, **_):
    print(f"\nContas criadas durante o teste: {len(CONTAS_CRIADAS)}")
