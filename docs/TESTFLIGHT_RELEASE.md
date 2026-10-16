# Publicar una actualización de Tesstats en TestFlight

Esta guía es el procedimiento operativo para subir futuras versiones de Tesstats a **TestFlight para pruebas internas**, o a la beta pública cuando el usuario lo solicite expresamente. No incluye publicar la app en el App Store.

## Alcance y datos fijos

- Destino por defecto: TestFlight, grupo interno `Internal Testers`.
- Si el usuario solicita también la beta pública: grupo externo existente `Public Beta`.
- Bundle ID principal: `com.tesstats.app`.
- Equipo de Apple Developer: `6RPLS9EA4X`.
- El proyecto de Xcode se genera desde `project.yml` y no se versiona.
- La distribución automática del grupo interno puede asignar una compilación procesada a sus testers. Esto no publica la app en el App Store.

Una subida a TestFlight no requiere completar la ficha pública, precio, disponibilidad comercial, capturas del App Store ni enviar una versión del App Store a revisión. Nunca pulses **Añadir a revisión** en la ficha del App Store para este flujo. La distribución externa puede requerir **Beta App Review**, que se tramita dentro de TestFlight.

## 1. Requisitos previos

Antes de empezar, comprueba:

1. macOS con una versión compatible de Xcode y sus herramientas de línea de comandos.
2. `xcodegen` instalado (`brew install xcodegen`).
3. La cuenta de Apple iniciada en Xcode, dentro de **Xcode → Settings → Accounts**.
4. Acceso a la app Tesstats en App Store Connect y al equipo configurado en `project.yml`.
5. Contratos o acuerdos pendientes de Apple aceptados. Si Apple solicita una acción legal o datos que no se puedan deducir del repositorio, detén el proceso y pide al titular de la cuenta que los complete.
6. Un árbol Git limpio o, como mínimo, una identificación explícita de todos los cambios que formarán parte de la beta.

No guardes claves, contraseñas, perfiles, certificados ni tokens dentro del repositorio. Las plantillas `Config/TestFlightExportOptions.plist` y `Config/TestFlightPublicBetaExportOptions.plist` contienen solamente opciones públicas de exportación y el identificador del equipo; no contienen credenciales.

## 2. Sincronizar y revisar el repositorio

Trabaja desde `main` actualizado y revisa los cambios antes de compilar:

```bash
git fetch origin
git switch main
git pull --ff-only origin main
git status --short
```

No descartes cambios preexistentes que no pertenezcan a la actualización. Confirma también que no se vayan a versionar artefactos locales:

```bash
git status --short --ignored
```

Los directorios de compilación, `.xcarchive`, `.xcresult`, símbolos, IPAs, perfiles, claves y capturas locales deben aparecer ignorados.

## 3. Elegir versión y número de compilación

Los dos valores están en `project.yml`:

```yaml
MARKETING_VERSION: "0.5.0"
CURRENT_PROJECT_VERSION: "12"
```

- `MARKETING_VERSION` es la versión visible, por ejemplo `0.5.1` o `0.6.0`.
- `CURRENT_PROJECT_VERSION` es el número de compilación. Debe ser un entero y ser **mayor que cualquier compilación ya subida para esa versión**.

Para corregir y volver a subir la misma versión, mantén `MARKETING_VERSION` e incrementa solamente `CURRENT_PROJECT_VERSION`. Apple no permite reutilizar un número de compilación, aunque la compilación anterior haya fallado o caducado.

Antes de editar, consulta en App Store Connect la compilación más reciente de TestFlight. Después actualiza `project.yml` y comprueba el resultado:

```bash
rg -n 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' project.yml
```

## 4. Regenerar el proyecto

Genera el proyecto desde su única fuente de verdad:

```bash
xcodegen generate
```

Nunca edites ni añadas `Tesstats.xcodeproj` a Git. Si cambias capacidades, recursos, identificadores o ajustes de firma, hazlo en `project.yml` y vuelve a generar.

## 5. Validar antes de archivar

Primero verifica la estructura del proyecto y ejecuta las pruebas relevantes. Para pruebas en simulador, elige un dispositivo que exista en la instalación local:

```bash
xcrun simctl list devices available
xcodebuild \
  -project Tesstats.xcodeproj \
  -scheme Tesstats \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  test
```

Si ese modelo no existe, sustituye `iPhone 16 Pro` por uno disponible. Como mínimo deben pasar las pruebas unitarias y las pruebas de interfaz relacionadas con los cambios. Corrige errores de compilación, firma, iconos o manifiestos de privacidad antes de continuar.

Haz también una compilación Release genérica con firma automática:

```bash
xcodebuild \
  -project Tesstats.xcodeproj \
  -scheme Tesstats \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  build
```

## 6. Crear el archivo de distribución

Lee la versión y la compilación ya elegidas y define una ruta explícita dentro del directorio ignorado `build/TestFlight`:

```bash
VERSION=$(awk -F '"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
BUILD=$(awk -F '"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
ARCHIVE_PATH="$PWD/build/TestFlight/Tesstats-${VERSION}-${BUILD}.xcarchive"
EXPORT_PATH="$PWD/build/TestFlight/export-${VERSION}-${BUILD}"
mkdir -p "$PWD/build/TestFlight"
```

Archiva la aplicación y todas sus extensiones:

```bash
xcodebuild \
  -project Tesstats.xcodeproj \
  -scheme Tesstats \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  clean archive
```

El comando debe finalizar con `** ARCHIVE SUCCEEDED **`. Revisa que el archivo incluya la app principal, widgets y app de Apple Watch y que no haya advertencias críticas de firma, iconos o privacidad.

## 7. Subir a App Store Connect

La plantilla versionada usa `destination=upload`, por lo que la exportación sube el archivo directamente a App Store Connect mediante la cuenta iniciada en Xcode.

La opción `testFlightInternalTestingOnly=true` restringe la compilación a los grupos internos de TestFlight.

Cuando el usuario haya solicitado expresamente la beta pública, usa en el comando siguiente `Config/TestFlightPublicBetaExportOptions.plist`, que establece `testFlightInternalTestingOnly=false`. Esto permite asignar la compilación al grupo externo; no publica la app en el App Store. Una compilación que ya se haya subido con la restricción interna requiere una nueva subida con un número de compilación mayor para poder distribuirse externamente.

```bash
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist Config/TestFlightExportOptions.plist \
  -allowProvisioningUpdates
```

La salida debe confirmar que la carga terminó correctamente. Si Xcode solicita autenticación, completa el inicio de sesión en Xcode y repite el comando. No copies credenciales al repositorio ni a la guía.

Para que las notificaciones remotas funcionen, la app exportada debe llevar APNs de
producción. Si la exportación conserva un IPA local, compruébalo sobre ese IPA —el
`.xcarchive` previo todavía puede estar firmado para desarrollo—:

```bash
IPA=$(find "$EXPORT_PATH" -maxdepth 1 -name '*.ipa' -print -quit)
CHECK_DIR=$(mktemp -d)
unzip -q "$IPA" -d "$CHECK_DIR"
APP=$(find "$CHECK_DIR/Payload" -maxdepth 1 -name '*.app' -type d -print -quit)
codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p - | rg 'aps-environment.*production'
```

La comprobación debe mostrar `aps-environment => production`. TestFlight nunca debe
usar el endpoint sandbox del microservicio; configura allí `APNS_PRODUCTION=true`.

Como alternativa manual, abre el `.xcarchive` en Xcode Organizer, elige **Distribute App → App Store Connect → Upload** y conserva la firma automática. Utiliza esta alternativa solamente si la exportación por terminal no funciona.

## 8. Verificar TestFlight

La aceptación de la carga no basta: Apple debe procesar la compilación.

1. Abre **App Store Connect → Apps → Tesstats → TestFlight**.
2. Espera a que desaparezca `Procesando` y confirma la versión y compilación exactas.
3. Responde la declaración de cifrado si Apple la solicita. Contesta según el comportamiento real de la app; no inventes una respuesta legal.
4. Comprueba que no existan errores de iconos, extensiones, privacidad o cumplimiento.
5. Añade una nota breve en inglés en **What to Test**, centrada en los cambios de esa compilación.
6. Confirma que la compilación está disponible para `Internal Testers`. Con distribución automática activa debería asignarse sola; si no ocurre, selecciónala manualmente dentro del grupo.
7. Confirma que los testers aparecen como invitados o activos y que pueden instalar la compilación desde TestFlight.
8. Abre una vez la nueva build en el iPhone para renovar y registrar su token APNs. En
   **Ajustes → Avisos**, usa primero la prueba local y después **Enviar prueba remota**.

Para pruebas internas no se requiere Beta App Review. Si algún paso intenta abrir la versión pública de iOS, vuelve a la pestaña **TestFlight**.

### Distribución externa solicitada expresamente

1. Conserva la asignación al grupo interno y añade la compilación procesada al grupo externo existente `Public Beta`.
2. Completa la información de pruebas y, si Apple lo solicita, envía la compilación a **Beta App Review** desde TestFlight. Utiliza los datos de revisión ya configurados; si falta información que no puedas determinar, solicítala al titular de la cuenta.
3. Activa la notificación a los testers al aprobarse la compilación si el flujo la ofrece. No cambies los límites o criterios del enlace público ni invites a otros testers salvo petición del usuario.
4. Confirma el estado de revisión, el enlace público y la disponibilidad para los testers externos. Si Apple aún no ha aprobado la beta, informa de que está pendiente y no la describas como disponible.

## 9. Límites: no publicar en el App Store

Durante este procedimiento:

- No selecciones la compilación en la ficha pública de la versión de iOS.
- No pulses **Añadir a revisión** ni **Enviar para revisión** en la ficha del App Store. El envío a **Beta App Review** dentro de TestFlight solo está autorizado cuando el usuario solicite distribución externa.
- No configures una fecha de publicación pública.
- No completes precio, disponibilidad, condición de comerciante, capturas o metadatos públicos salvo que el usuario lo pida de forma explícita en otra tarea.
- No confundas la distribución automática de un grupo de TestFlight con la publicación automática del App Store: son controles distintos.

La ficha pública puede permanecer en `En preparación para el envío` indefinidamente sin afectar TestFlight.

## 10. Cerrar la actualización

Cuando App Store Connect confirme la compilación:

1. Revisa `git diff` y `git status`.
2. Versiona el cambio de versión/compilación junto con el código que se probó.
3. No añadas archivos dentro de `build/`, `.xcarchive`, `.xcresult`, IPAs ni material de firma.
4. Integra mediante avance rápido o un commit normal en `main`, según el flujo de trabajo del repositorio.
5. Ejecuta `git push origin main` y verifica que `origin/main` apunta al commit esperado.

El informe final debe incluir:

- Versión y número de compilación.
- Resultado de pruebas y archivo.
- Confirmación de procesamiento en App Store Connect.
- Grupo de TestFlight asignado y estado de los testers.
- Hash del commit enviado a `main`.
- Cualquier acción pendiente del titular de la cuenta.

## Problemas frecuentes

### El número de compilación ya existe

Incrementa `CURRENT_PROJECT_VERSION`, regenera el proyecto, vuelve a archivar y sube de nuevo.

### No se encuentra un perfil o certificado

Comprueba la cuenta y el equipo en Xcode. Usa `-allowProvisioningUpdates` y conserva `CODE_SIGN_STYLE: Automatic`. No descargues ni subas perfiles al repositorio.

### Falta el icono de Apple Watch

Verifica `TesstatsWatch/Assets.xcassets/AppIcon.appiconset` y los ajustes `INFOPLIST_KEY_CFBundleIconName` y `ASSETCATALOG_COMPILER_APPICON_NAME` de `project.yml`; después regenera y archiva.

### Apple marca un problema de privacidad

Revisa los archivos `PrivacyInfo.xcprivacy` de la app y sus extensiones. Declara únicamente las APIs y finalidades realmente utilizadas.

### La compilación se subió pero no aparece en el grupo

Espera a que termine el procesamiento, resuelve cualquier declaración pendiente y comprueba la distribución automática del grupo `Internal Testers`. Si sigue sin asignarse, añádela manualmente desde la sección TestFlight, nunca desde la ficha pública.
