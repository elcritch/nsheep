(function() {
  var theme = localStorage.getItem('nimpack-theme');
  if (!theme && window.matchMedia) {
    theme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  document.documentElement.setAttribute('data-theme', theme || 'light');
})();
