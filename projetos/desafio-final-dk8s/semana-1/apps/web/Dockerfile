# syntax=docker/dockerfile:1.7
# =============================================================================
# Imagem: Chainguard Nginx (roda como user non-root por default).
# Imagem minimalista baseada em Wolfi OS, com zero vulnerabilidades conhecidas.
# =============================================================================
FROM cgr.dev/chainguard/nginx:latest

EXPOSE 8080

# Configuracao do nginx (proxy reverso pras APIs)
# A imagem da Chainguard espera a config em /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Arquivos estaticos do frontend
COPY html/ /usr/share/nginx/html/