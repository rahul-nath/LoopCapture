// A file input alone does not handle clipboard files. This component accepts
// both paste and drop, emits a File, and leaves unsupported pastes untouched.
export class ClipInput extends HTMLElement {
  #previewURL;

  connectedCallback() {
    if (this.firstElementChild) return;
    this.innerHTML = `
      <label>Choose an image or video <input type="file" accept="image/*,video/*"></label>
      <div class="paste-zone" contenteditable="true" role="textbox" aria-label="Paste an image or video" tabindex="0">Click here, then press ⌘V. You can also drop a clip.</div>
      <output aria-live="polite"></output><div class="preview"></div>`;
    this.addEventListener('paste', event => {
      if (this.#receive(event.clipboardData?.files)) event.preventDefault();
    });
    this.addEventListener('dragover', event => event.preventDefault());
    this.addEventListener('drop', event => {
      if (this.#receive(event.dataTransfer?.files)) event.preventDefault();
    });
    this.querySelector('input').addEventListener('change', event => this.#receive(event.target.files));
  }

  disconnectedCallback() {
    if (this.#previewURL) URL.revokeObjectURL(this.#previewURL);
    this.#previewURL = undefined;
  }

  #receive(files) {
    const candidates = Array.from(files ?? []);
    const file = candidates.find(file => file.type.startsWith('video/')) ??
      candidates.find(file => file.type.startsWith('image/'));
    if (!file) return false;
    const transfer = new DataTransfer();
    transfer.items.add(file);
    this.querySelector('input').files = transfer.files;
    if (this.#previewURL) URL.revokeObjectURL(this.#previewURL);
    this.#previewURL = URL.createObjectURL(file);
    const media = document.createElement(file.type.startsWith('video/') ? 'video' : 'img');
    if (media instanceof HTMLVideoElement) {
      media.autoplay = true;
      media.muted = true;
      media.loop = true;
      media.controls = true;
    } else {
      media.alt = file.name;
    }
    media.src = this.#previewURL;
    this.querySelector('.preview').replaceChildren(media);
    this.querySelector('output').textContent = `${file.name} · ${file.type} · ${file.size.toLocaleString()} bytes`;
    this.querySelector('.paste-zone').textContent = 'Clip accepted. Paste another to replace it.';
    this.dispatchEvent(new CustomEvent('clipchange', { detail: file, bubbles: true, composed: true }));
    return true;
  }
}

customElements.define('clip-input', ClipInput);
