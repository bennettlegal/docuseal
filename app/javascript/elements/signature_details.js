// Fit the full annotation; the signature image has its own independent space.
export default class extends HTMLElement {
  connectedCallback () {
    this.resizeObserver = new ResizeObserver(() => this.scheduleFit())
    this.resizeObserver.observe(this)
    this.contentObserver = new MutationObserver(() => this.scheduleFit())
    this.contentObserver.observe(this, { childList: true, subtree: true, characterData: true })
    this.fontsLoaded = () => this.scheduleFit()
    document.fonts?.addEventListener('loadingdone', this.fontsLoaded)
    document.fonts?.ready.then(() => { if (this.isConnected) this.scheduleFit() })
    this.scheduleFit()
  }

  disconnectedCallback () {
    this.resizeObserver?.disconnect()
    this.contentObserver?.disconnect()
    document.fonts?.removeEventListener('loadingdone', this.fontsLoaded)
    cancelAnimationFrame(this.frame)
  }

  scheduleFit () {
    cancelAnimationFrame(this.frame)
    this.frame = requestAnimationFrame(() => this.fit())
  }

  fit () {
    const content = this.firstElementChild
    if (!content || !this.isConnected) return

    const style = getComputedStyle(this)
    const width = this.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)
    const height = this.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom)
    if (width <= 0 || height <= 0) return

    const bounds = this.getBoundingClientRect()
    const maximum = parseFloat(style.fontSize)
    const fits = size => {
      content.style.fontSize = `${size}px`
      if (content.scrollWidth > Math.floor(width) || content.scrollHeight > Math.floor(height)) return false

      // Fonts can draw outside their line boxes even when scrollHeight fits.
      const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT)
      while (walker.nextNode()) {
        if (!walker.currentNode.textContent.trim()) continue
        const range = document.createRange()
        range.selectNodeContents(walker.currentNode)
        for (const rect of range.getClientRects()) {
          if (rect.left < bounds.left || rect.right > bounds.right || rect.top < bounds.top || rect.bottom > bounds.bottom) return false
        }
      }
      return true
    }
    if (fits(maximum)) return

    let low = 0.1
    let high = maximum
    for (let index = 0; index < 14; index++) {
      const size = (low + high) / 2
      if (fits(size)) low = size
      else high = size
    }
    content.style.fontSize = `${low}px`
  }
}
