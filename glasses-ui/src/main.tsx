import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';

// Toolkit styles. These install the theme CSS variables, type scale, and
// focus/interaction styling the components rely on.
import '@wearables-ui-toolkit/foundation/styles.css';
import '@wearables-ui-toolkit/mrbd/styles.css';

import { Preview } from './Preview';
import './preview.css';

const root = createRoot(document.getElementById('root')!);
root.render(
  <StrictMode>
    <Preview />
  </StrictMode>,
);
