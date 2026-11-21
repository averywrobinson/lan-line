// Same theme as the page's original inline Tailwind config (CDN play build), compiled ahead of time.
// Build: tools/build-site-css.sh  ->  site/tailwind.css
module.exports = {
  content: ['./site/index.html'],
  darkMode: 'class',
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', '-apple-system', 'BlinkMacSystemFont', 'SF Pro Display', 'sans-serif'],
        mono: ['JetBrains Mono', 'ui-monospace', 'SFMono-Regular', 'monospace'],
      },
      colors: {
        obsidian: '#080A0F',
        emeraldSignal: '#34D399',
      },
      letterSpacing: {
        tightest: '-0.038em',
        tighterDisplay: '-0.035em',
      },
    },
  },
};
