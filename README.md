# Org Dynamic Block Evidence-Based Scheduling #

This library implements [Evidence-Based Scheduling (EBS)][ebs] forecasting for
projects within [Org Mode][org-mode].  This is primarily accomplished by using
[Org Mode's][org-mode] [Dynamic Blocks][org-dblocks].

That is, insert the following into the project entry and update the block via
`C-c C-c`.  By default this will output the projected "ship" dates of the
project using the following confidence intervals: 5%, 50%, and 95% given 8 hour
work days.

The following is an example of how to use this code within your projects.

```org
#+BEGIN: ebs-forecast :scope subtree :work-hours 8 :iterations 100 :pvals (0.05 0.5 0.95)
#+END:
```

All of the above parameters, sans `:scope`, are default values, thus, the
following is equivalent:

```org
#+BEGIN: ebs-forecase :scope subtree
#+END:
```

You may, of course, change the default confidence intervals and work-hours, as
well as, the default "random" velocities to assign when starting your
[EBS][ebs] tracking.

## Setup ##

Install the package and require the top-level `org-dblock-ebs` code via your
typical means.

Then require the module and, optionally (but strongly encouraged), enable the
velocity recording hook.

```elisp
(use-package org-dblock-ebs
  :hook (org-after-todo-state-change-hook . org-ebs-record-velocity))
```

## License ##

This code is released, AS-IS and WITHOUT WARRANTY, as free and open source
software in the expressed hopes that it is useful, under the terms and
conditions of the [GNU General Public License (version 3)][gpl-3].

[ebs]: https://www.joelonsoftware.com/2007/10/26/evidence-based-scheduling/

[gpl-3]: https://www.gnu.org/licenses/gpl-3.0

[org-mode]: https://orgmode.org/

[org-dblocks]: https://orgmode.org/manual/Dynamic-Blocks.html
