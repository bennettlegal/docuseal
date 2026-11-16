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

    const maximum = parseFloat(style.fontSize)
    const fits = size => {
      content.style.fontSize = `${size}px`
      return content.scrollWidth <= Math.floor(width) && content.scrollHeight <= Math.floor(height)
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
