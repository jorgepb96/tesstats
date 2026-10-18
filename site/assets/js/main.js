const header = document.querySelector('[data-header]')
const menuButton = document.querySelector('[data-menu-button]')
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches

const updateHeader = () => {
  header?.classList.toggle('is-scrolled', window.scrollY > 24)
}

updateHeader()
window.addEventListener('scroll', updateHeader, { passive: true })

const navigation = header?.querySelector('.nav-links')
const closeMenu = (restoreFocus = false) => {
  header?.classList.remove('menu-open')
  menuButton?.setAttribute('aria-expanded', 'false')
  menuButton?.setAttribute('aria-label', 'Open menu')
  if (restoreFocus) menuButton?.focus()
}

if (menuButton && navigation) {
  navigation.id = 'site-navigation'
  menuButton.setAttribute('aria-controls', navigation.id)
  menuButton.addEventListener('click', () => {
    const isOpen = header.classList.toggle('menu-open')
    menuButton.setAttribute('aria-expanded', String(isOpen))
    menuButton.setAttribute('aria-label', isOpen ? 'Close menu' : 'Open menu')
  })
  navigation.querySelectorAll('a').forEach((link) => {
    link.addEventListener('click', () => closeMenu())
  })
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && header.classList.contains('menu-open')) closeMenu(true)
  })
  document.addEventListener('click', (event) => {
    if (!header.contains(event.target)) closeMenu()
  })
  window.addEventListener('resize', () => {
    if (window.innerWidth > 900) closeMenu()
  }, { passive: true })
  header.classList.add('menu-ready')
}

// Live GitHub star count, best effort: the badge reads fine without it.
const starCounts = document.querySelectorAll('[data-star-count]')

if (starCounts.length) {
  fetch('https://api.github.com/repos/jorgepb96/tesstats', { cache: 'no-store' })
    .then((response) => (response.ok ? response.json() : null))
    .then((result) => {
      const value = result && Number(result.stargazers_count)
      if (!Number.isFinite(value)) return
      const label = value >= 1000 ? `${(value / 1000).toFixed(1)}k` : String(value)
      starCounts.forEach((element) => {
        element.textContent = label
        element.setAttribute('aria-label', `${value} stars on GitHub`)
      })
    })
    .catch(() => {})
}

document.querySelectorAll('[data-delay]').forEach((element) => {
  element.style.setProperty('--delay', `${element.dataset.delay}ms`)
})

const revealElements = document.querySelectorAll('.reveal')

if (reducedMotion || window.matchMedia('(max-width: 900px), (hover: none)').matches || !('IntersectionObserver' in window)) {
  revealElements.forEach((element) => element.classList.add('is-visible'))
} else {
  const revealObserver = new IntersectionObserver((entries, observer) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return
      entry.target.classList.add('is-visible')
      observer.unobserve(entry.target)
    })
  }, { rootMargin: '0px 0px -7% 0px', threshold: 0.08 })

  revealElements.forEach((element) => revealObserver.observe(element))
}

document.querySelectorAll('[data-year]').forEach((element) => {
  element.textContent = String(new Date().getFullYear())
})

const screenRail = document.querySelector('[data-screen-rail]')
const screenPrev = document.querySelector('[data-screen-prev]')
const screenNext = document.querySelector('[data-screen-next]')

if (screenRail) {
  const scrollStep = () => Math.min(screenRail.clientWidth * 0.82, 620)
  const updateScreenControls = () => {
    const atStart = screenRail.scrollLeft <= 4
    const atEnd = screenRail.scrollLeft + screenRail.clientWidth >= screenRail.scrollWidth - 4
    if (screenPrev) screenPrev.disabled = atStart
    if (screenNext) screenNext.disabled = atEnd
  }
  const moveScreens = (direction) => {
    screenRail.scrollBy({
      left: direction * scrollStep(),
      behavior: reducedMotion ? 'auto' : 'smooth'
    })
  }

  screenPrev?.addEventListener('click', () => moveScreens(-1))
  screenNext?.addEventListener('click', () => moveScreens(1))

  screenRail.addEventListener('keydown', (event) => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
    event.preventDefault()
    moveScreens(event.key === 'ArrowLeft' ? -1 : 1)
  })

  let isDragging = false
  let dragStartX = 0
  let dragStartScroll = 0

  screenRail.addEventListener('pointerdown', (event) => {
    if (event.pointerType === 'touch' || event.button !== 0) return
    isDragging = true
    dragStartX = event.clientX
    dragStartScroll = screenRail.scrollLeft
    screenRail.classList.add('is-dragging')
    screenRail.setPointerCapture(event.pointerId)
  })

  screenRail.addEventListener('pointermove', (event) => {
    if (!isDragging) return
    event.preventDefault()
    screenRail.scrollLeft = dragStartScroll - (event.clientX - dragStartX)
  })

  const stopDragging = (event) => {
    if (!isDragging) return
    isDragging = false
    screenRail.classList.remove('is-dragging')
    if (screenRail.hasPointerCapture(event.pointerId)) {
      screenRail.releasePointerCapture(event.pointerId)
    }
  }

  screenRail.addEventListener('pointerup', stopDragging)
  screenRail.addEventListener('pointercancel', stopDragging)
  screenRail.addEventListener('dragstart', (event) => event.preventDefault())
  screenRail.addEventListener('scroll', updateScreenControls, { passive: true })
  window.addEventListener('resize', updateScreenControls, { passive: true })
  window.addEventListener('load', updateScreenControls, { once: true })
  requestAnimationFrame(updateScreenControls)
}

if (!reducedMotion && window.matchMedia('(min-width: 901px) and (hover: hover) and (pointer: fine)').matches) {
  const heroVisual = document.querySelector('.hero-visual')

  window.addEventListener('pointermove', (event) => {
    if (!heroVisual || window.innerWidth < 900) return
    const x = (event.clientX / window.innerWidth - 0.5) * 10
    const y = (event.clientY / window.innerHeight - 0.5) * 8
    heroVisual.style.setProperty('transform', `translate3d(${x}px, ${y}px, 0)`)
  }, { passive: true })
}
