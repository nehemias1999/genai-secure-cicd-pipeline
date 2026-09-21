// =============================================================================
// Jenkinsfile — Pipeline CI/CD declarativo (requisito cicd-pipeline)
// -----------------------------------------------------------------------------
// Proposito: orquesta el ciclo completo validacion -> build -> scan de
//   seguridad -> publicacion consumiendo los scripts ya mergeados bajo scripts/
//   (run-trivy.sh, publish.sh) y el helper de trazabilidad build-metadata.sh.
//   El Jenkinsfile queda fino y declarativo (D5 de design.md: scripts sobre
//   inline); toda logica no trivial vive en scripts/ y es verificable con
//   bash -n. Sin Jenkins real en el entorno de desarrollo: la verificacion de
//   este archivo es estructural (orden de stages, failFast, archiveArtifacts,
//   credenciales y gate de secretos).
// Trigger: cualquier push/PR al repo. La publicacion REAL queda a criterio del
//   operador (env PUBLISH_MODE=real + credencial WIF en el secret store de
//   Jenkins) y solo desde la rama main; en PRs el stage Publish corre siempre
//   en --dry-run (valida sin tocar red).
// Env Vars (operador; el Jenkinsfile nunca contiene valores secretos):
//   IMAGE_NAME    nombre de la imagen local (default: genai-secure-api)
//   IMAGE_TAG     tag local del build (default: latest; es el SOURCE_TAG que
//                 consume scripts/publish.sh)
//   PUBLISH_MODE  dry-run (default) | real — el modo real exige la credencial
//                 WIF provisionada en Jenkins (withCredentials)
//   REGION, PROJECT_ID, REGISTRY_REPO  target de Artifact Registry (operador);
//                 si faltan, publish.sh falla con mensaje claro (nunca adivina)
// Dependencies (agente): git, python3 + pytest + flake8 (requirements-dev.txt),
//   docker o podman, trivy (TRIVY_BIN), jq
// =============================================================================
pipeline {
  // El agente debe proveer git, python3, docker/podman, trivy y jq (header).
  agent any

  options {
    disableConcurrentBuilds()   // evita colisiones sobre el tag local de imagen
    timeout(time: 30, unit: 'MINUTES') // cota maxima del ciclo de vida completo
    skipDefaultCheckout()       // el checkout se hace explicito en el stage 1
  }

  environment {
    IMAGE_NAME = "${env.IMAGE_NAME ?: 'genai-secure-api'}"
    IMAGE_TAG = "${env.IMAGE_TAG ?: 'latest'}"
    PUBLISH_MODE = "${env.PUBLISH_MODE ?: 'dry-run'}"
  }

  stages {
    stage('Checkout & Lint') {
      steps {
        checkout scm  // fija GIT_COMMIT/GIT_BRANCH; workspace limpio con el repo
        sh '''#!/usr/bin/env bash
          set -euo pipefail
          # Gate de linting (spec: los errores de flake8 rompen el pipeline).
          # Politica documentada: max-line-length 88 (estilo real del repo,
          # alineado a black) y W292 ignorado (newline final: formato, no logica);
          # cualquier error pyflakes (nombres, imports, sintaxis) rompe el build.
          python3 -m flake8 --max-line-length=88 --extend-ignore=W292 src/ tests/
        '''
      }
    }

    stage('Unit tests') {
      steps {
        sh '''#!/usr/bin/env bash
          set -euo pipefail
          # Gate de tests (spec: tests fallidos rompen el pipeline).
          python3 -m pytest -q tests/
        '''
      }
    }

    stage('Build') {
      steps {
        sh '''#!/usr/bin/env bash
          set -euo pipefail
          CTR_CMD="${CTR_CMD:-docker}"  # podman es drop-in para docker build
          # Build args de trazabilidad OCI que consume el Dockerfile: la revision
          # git (GIT_COMMIT lo fija el checkout), la URL de origen y el timestamp.
          GIT_SHA="${GIT_COMMIT:-unknown}"
          REPO_URL="$(git config --get remote.origin.url 2>/dev/null || printf '')"
          # Si la URL trae userinfo embebida (https://user:token@host/...), se
          # descarta: los labels OCI de la imagen nunca deben transportar creds.
          if [[ "$REPO_URL" == *"://"* ]]; then
            REPO_URL="${REPO_URL#*://}"
            REPO_URL="${REPO_URL#*@}"
            REPO_URL="https://${REPO_URL}"
          fi
          BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          "$CTR_CMD" build \
            --build-arg GIT_SHA="$GIT_SHA" \
            --build-arg REPO_URL="$REPO_URL" \
            --build-arg BUILD_TIMESTAMP="$BUILD_TIMESTAMP" \
            --tag "${IMAGE_NAME}:${IMAGE_TAG}" .
        '''
      }
    }

    stage('Security Scan') {
      steps {
        sh '''#!/usr/bin/env bash
          set -euo pipefail
          # Scan de la imagen local + reports trazables bajo reports/. El gate
          # CRITICAL/HIGH rompe el build (exit 1); el scan fs es no-bloqueante.
          bash scripts/run-trivy.sh "${IMAGE_NAME}:${IMAGE_TAG}" reports/
          # Trazabilidad de build (task 6.3): metadata JSON con commit SHA + build
          # URL + digest producido (autoritativo: ScanTrace del report de trivy).
          bash scripts/build-metadata.sh "${IMAGE_NAME}:${IMAGE_TAG}" reports/
        '''
      }
    }

    stage('Publish') {
      steps {
        script {
          // Gate de publicacion (fail-closed): REAL solo con PUBLISH_MODE=real
          // desde main y con la credencial WIF del secret store de Jenkins
          // (withCredentials, nunca valores estaticos). Cualquier otro caso
          // (PRs, env ausente) corre publish.sh en --dry-run: valida resolucion
          // semver + tags locales + digest sin tocar red.
          if (env.PUBLISH_MODE == 'real' && env.BRANCH_NAME == 'main') {
            withCredentials([file(credentialsId: 'gcp-wif-credential-file', variable: 'CI_IAM_CREDENTIALS_FILE')]) {
              sh '''#!/usr/bin/env bash
                set -euo pipefail
                # Push real a Artifact Registry via WIF. CI_IAM_CREDENTIALS_FILE
                # lo inyecta withCredentials; shell sin xtrace para no loguear nada.
                IMAGE="${IMAGE_NAME}" SOURCE_TAG="${IMAGE_TAG}" bash scripts/publish.sh
              '''
            }
          } else {
            sh '''#!/usr/bin/env bash
              set -euo pipefail
              # Dry-run seguro: validacion local completa, sin red ni push.
              IMAGE="${IMAGE_NAME}" SOURCE_TAG="${IMAGE_TAG}" bash scripts/publish.sh --dry-run
            '''
          }
        }
      }
    }
  }

  post {
    always {
      // Archiva reports de trivy + build-metadata.json (trazabilidad) y los
      // deja disponibles como artifacts del build aunque un gate haya fallado.
      archiveArtifacts artifacts: 'reports/**/*', fingerprint: true, allowEmptyArchive: true
    }
  }
}