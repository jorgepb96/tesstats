# Auditoría de cálculos y funciones de Tesstats

Fecha: 11 de octubre de 2026. Versión revisada: 5.6.2, build 36.

La revisión ha encontrado y corregido errores en consumos con datos ausentes, eficiencia y gastos de carga, tarifas por franjas, pérdidas al aparcar y carga del historial. También se han corregido incoherencias de unidades, gráficos de viajes y aislamiento de datos entre servidores. La validación combina pruebas de cálculo, respuestas de API simuladas, pruebas de interfaz y compilación para Mac.

## Cálculos corregidos

| Área | Problema encontrado | Resultado de la corrección |
| --- | --- | --- |
| Eficiencia y pérdidas de carga | La energía añadida de sesiones sin contador de red se dividía por la energía de red de otras sesiones. Se podía mostrar un 100 % artificial y ocultar pérdidas. | Se comparan únicamente las parejas válidas de energía añadida y energía de red de las mismas sesiones. Las mediciones inconsistentes se consideran desconocidas. |
| Precio medio por kWh | Se usaban únicamente costes registrados y energía añadida, aunque el total de gastos incluía estimaciones y pérdidas de carga. | Se divide la suma de costes efectivos por la energía facturada correspondiente, incluyendo tarifas por ubicación y cargas gratuitas. |
| Gastos estimados | Bastaba una sesión con coste registrado para presentar todo el periodo como registrado. | El resumen indica estimación si alguna sesión usa un coste calculado. |
| Importes registrados pequeños | Un importe registrado de 0,01 se sustituía por una estimación. | Todo importe positivo y finito registrado conserva su prioridad. |
| Tarifas por franjas | El muestreo desde el segundo de inicio y el truncamiento de minutos desplazaban cambios de franja y omitían fracciones de la sesión. | La media pondera segundos efectivos dentro de cada minuto del reloj, incluidos intervalos cortos y cambios de horario de verano e invierno. |
| Consumo agregado de viajes | La distancia de viajes sin energía conocida diluía el consumo calculado. | El denominador incluye únicamente la distancia de viajes con energía conocida. La distancia total del periodo sigue incluyendo todos los viajes. |
| Descarga en reposo | Una media simple de tasas diarias daba el mismo peso a aparcamientos de distinta duración. Una carga que empezaba antes del aparcamiento podía pasar inadvertida. | La tasa es pérdida total dividida por tiempo observado. Se excluyen cargas cuyos intervalos se solapan con el aparcamiento. |
| Energía perdida al aparcar | Se suponía una batería de 75 kWh para todos los vehículos y se ignoraban sesiones de carga sin fecha de finalización. | Se usa capacidad disponible o deducida del vehículo; si falta, se recurre a autonomía y eficiencia nominal cuando están disponibles. Se excluyen aparcamientos solapados con cargas abiertas. |
| Potencia por ubicación | Una sesión corta y rápida tenía el mismo peso que una sesión larga y lenta. | La potencia media se pondera por la duración de las sesiones. |
| Degradación y capacidad mensual | La autonomía máxima y la capacidad podían proceder de observaciones distintas según el orden de entrada. | Se mantiene la capacidad asociada a la observación de mayor autonomía, con recuperación de capacidad disponible cuando esa observación no la contiene. |
| Periodos y proyecciones | Algunas operaciones ignoraban la fecha de referencia recibida. Una selección histórica proyectaba sus gastos hasta el día actual. Las cargas inferiores a 1 kWh podían suprimir la comparación mensual. | Se propaga la fecha de referencia, se limita la proyección al final del periodo seleccionado y se cuenta actividad por sesiones. Los filtros recientes excluyen fechas futuras y los intervalos personalizados invertidos son seguros. |
| Unidades del historial | Se trataban millas y Fahrenheit del servidor como kilómetros y Celsius. Además, algunas gráficas mostraban valores métricos con rótulos imperiales. | Se normaliza el historial antes de calcular y exportar. En respuestas imperiales, el consumo se obtiene de los kWh netos y la distancia normalizada cuando esos datos están disponibles. Se convierten los valores de las gráficas de consumo, velocidad y autonomía. |
| Telemetría de viajes | Se generaban ondulaciones de velocidad sin muestras reales y energía restante basada en una batería fija. | Se representa la velocidad media disponible y se aclara que las gráficas usan resúmenes. La energía restante se muestra únicamente con capacidad y estado inicial de batería disponibles. |
| Consumo y coste en directo | El ajuste visual de velocidad GPS entraba en la distancia integrada y lecturas antiguas de potencia o velocidad podían renovarse con mensajes de otras métricas. El estimador de movimiento era compartido entre coches. | La integración usa velocidad sin ajuste visual y muestras con fecha propia, que caducan a los cinco segundos. Solo una velocidad cero puede conservarse al aparcar. El movimiento se conserva por vehículo. El GPS solo no proporciona una medición de energía. |

## Ejemplos numéricos de verificación

- Una carga con 18 kWh añadidos y 20 kWh de red, junto con otra de 40 kWh sin medición de red, conserva una eficiencia medible del 90 % y pérdidas conocidas de 2 kWh.
- Un gasto registrado de 6 para 20 kWh facturados, otro estimado de 2 para 10 kWh y una carga gratuita de 5 kWh dan un gasto total de 8 y un precio medio de 8 / 35 = 0,228571 por kWh.
- Viajes de 10 km a 300 Wh/km y 90 km a 100 Wh/km dan 120 Wh/km. Un viaje adicional de 100 km sin energía conocida no reduce esa cifra a 60 Wh/km.
- Una sesión de 07:59:45 a 08:00:45 con precios de 0,10 antes de las 08:00 y 0,30 después da 0,25 por kWh: 15 segundos baratos y 45 segundos caros.
- Una pérdida de 6 puntos de batería durante un día y otra de 6 puntos durante tres días dan 3 puntos por día sobre cuatro días observados.
- Una pérdida del 2 % con una capacidad de 60 kWh equivale a 1,2 kWh; a 0,20 por kWh cuesta 0,24.

## Funciones corregidas

| Función | Corrección |
| --- | --- |
| Descarga completa del historial | Se elimina el límite silencioso de 50 páginas, que recortaba viajes y cargas a 5.000 registros. Hay pruebas con 5.001 registros de cada tipo. Las páginas repetidas producen un error explícito. |
| Sincronización incremental | La detección de orden descendente comprueba toda la página, además de conservar la prioridad de los registros descargados sobre los almacenados. |
| Cambio de vehículo | Se cancela la petición del coche anterior, se vacían sus datos y se impide que una respuesta cancelada sustituya los del coche actual. |
| Cambio de configuración o servidor | Se reinicia y vuelve a cargar el historial. Los estados en memoria y acumuladores se reinician al cambiar de fuente. |
| Caché y etiquetas entre servidores | Se separan por identidad de la fuente para evitar colisiones entre coches y viajes con el mismo ID en bases de datos distintas. El tamaño y borrado de caché incluyen los subdirectorios. |
| Perfiles guardados | Los perfiles usan el mismo almacén de preferencias que la configuración que los contiene. Se verifica guardado, renombrado, restauración y eliminación. |
| Copias cifradas | Se rechazan formatos, versiones, sal y parámetros de derivación inválidos antes de convertir enteros o realizar trabajo costoso. Se verifican recuperación, contraseña incorrecta y manipulación. |
| Rutas y elevación | Al descartar una coordenada inválida se descarta también su elevación, manteniendo las dos series alineadas. |

## Validación

La batería inicial contenía 113 pruebas unitarias y pasó completa. Se añadieron 41 pruebas de cálculo, contratos de API y funciones. Las pruebas de interfaz fijan el idioma cuando verifican textos concretos, comprueban la visibilidad tras desplazarse y respetan el ajuste configurable de velocidad GPS y los módulos actuales del conductor.

Resultados de la validación:

- **154 pruebas unitarias aprobadas, sin fallos.** Incluyen las 113 existentes y las 41 añadidas durante la auditoría.
- **17 pruebas funcionales de interfaz aprobadas, sin fallos**, en iPhone 16 Pro con iOS 18.2 Simulator. Se volvieron a ejecutar los flujos afectados de cargas y conductor después de las últimas correcciones. La prueba que solo captura la galería de imágenes quedó fuera de la ejecución funcional.
- **4 pruebas del servidor de recordatorios aprobadas, sin fallos**, con `npm test` en `server`.
- **Compilación correcta para iOS Simulator y macOS.** Los destinos de Watch y widgets se compilan como dependencias de la app iOS.
- Proyecto generado desde `project.yml` con XcodeGen y `git diff --check` sin incidencias. Los resultados de Xcode y registros se mantienen fuera del repositorio.

Las pruebas cubren tarifas y precios gratuitos, gastos registrados y estimados, exportación CSV y JSON, GPX, filtros de fechas y ubicaciones, sincronización y reintentos, persistencia, etiquetas, recordatorios y notificaciones, paquetes MQTT fragmentados, cálculo de consumo en directo, selección de fuentes de velocidad y protocolo Bluetooth de lectura. Las pruebas de interfaz recorren resumen, viajes y aparcamientos, cargas y sus filtros, batería, estadísticas, ajustes, avisos, mapas ampliados y pantalla del conductor en ambas orientaciones.

## Alcance y condiciones de las estimaciones

Los costes por franjas siguen siendo estimaciones basadas en flujo uniforme de energía y en la zona horaria del dispositivo. Las sesiones excepcionalmente largas usan como máximo siete días para acotar el cálculo. El coste registrado por TeslaMate conserva la prioridad. Un coste registrado de cero sigue tratándose como ausente porque el servidor puede usar ese valor cuando no hay tarifa; una ubicación configurada explícitamente a cero permite cargas gratuitas.

La degradación deducida, la autonomía a carga completa y las pérdidas en reposo dependen de las lecturas de batería y autonomía disponibles. El coste por 100 km compara cargas y distancia del periodo; el coste asignado a cada viaje usa el inventario ponderado de energía cargada. Esas dos métricas pueden diferir por energía que permanece en la batería o se consume en reposo. La comparación de CO₂ usa gasolina evitada y emisiones de combustión; no incluye generación eléctrica ni fabricación. La clasificación AC/DC del listado es una inferencia por potencia media cuando la API no aporta el tipo de cargador.

Las cachés antiguas sin identificación del servidor se vuelven a descargar en la primera conexión. Las etiquetas antiguas se atribuyen una sola vez a la fuente configurada y después se conservan por separado.

La validación automática comprueba lógica y flujos locales. La entrega real de APNs, una conexión Bluetooth con el coche, precisión de GPS, actualizaciones del Watch y ejecución de widgets o Live Activities en dispositivos físicos requieren esos dispositivos y servicios. La compilación de sus destinos no equivale a una prueba de entrega o conectividad real.

## Contrato externo contrastado

La normalización de unidades y la paginación se contrastaron con el código de [TeslaMateApi para viajes](https://github.com/tobiasehlert/teslamateapi/blob/3e158df077165237130072c82d07878ab448f4f8/src/v1_TeslaMateAPICarsDrives.go) y [cargas](https://github.com/tobiasehlert/teslamateapi/blob/3e158df077165237130072c82d07878ab448f4f8/src/v1_TeslaMateAPICarsCharges.go). Las respuestas simuladas reproducen sus unidades y campos; no sustituyen una comprobación contra una instalación concreta del usuario.
