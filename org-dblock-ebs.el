;;; -*- lexical-binding: t -*-
;;; org-dblock-ebs --- Produce EBS Forecasts using dynamic blocks
;;; Commentary:
;;; org-dblock-ebs
;;; Copyright (C) 2026  Kenny Ballou

;;; This program is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.

;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Code:

(require 'sqlite)
(require 'org-clock)
(require 'org-id)

(defgroup org-ebs nil
  "Evidence-Based Scheduling integration for Org mode."
  :group 'org)

(defcustom org-ebs-db-file (locate-user-emacs-file "org-ebs-velocities.sqlite")
  "The absolute path to the native SQLite database storing velocities."
  :type 'file
  :group 'org-ebs)

(defcustom org-ebs-working-hours-per-day 8
  "Number of expected working hours in a standard business day."
  :type 'integer
  :group 'org-ebs)

(defcustom org-ebs-simulation-iterations 100
  "Number of iterations to execute the simulation for forecasting."
  :type 'integer
  :group 'org-ebs)

(defcustom org-ebs-confidence-intervals '(0.05 0.50 0.95)
  "p-values to forecast schedule delivery dates."
  :type (list 'float)
  :group 'org-ebs)

(defcustom org-ebs-random-velocities '(0.3 0.5 0.7 1.5 2.0 3.0)
  "A random set of velocities to use for simulation when missing sufficient history."
  :type (list 'float)
  :group 'org-ebs)

(defvar org-ebs--db nil "Internal reference to the active database connection.")

(defun org-get-closed-time (pom &optional inherit)
  "Get the CLOSED as a time, otherwise nil."
  (let ((time (org-entry-get pom "CLOSED" inherit)))
    (when time
      (org-time-string-to-time time))))

(defun org-ebs--get-task-data ()
  "Extract the ID, effort, and clocked time for the task at point."
  (let* ((effort-str (org-entry-get nil org-effort-property))
         (effort (if effort-str (org-duration-to-minutes effort-str) 0))
         (clocked-time (org-clock-sum-current-item (org-clock-get-sum-start)))
         (task-id (org-id-get-create))
         (done? (org-entry-is-done-p))
         (closed-time (org-get-closed-time nil)))
    (list :id task-id
          :done? done?
          :effort effort
          :clocked clocked-time
          :closed-time closed-time)))

(defun org-ebs--get-pending-tasks ()
  "Traverse the current subtree and extract all pending actionable tasks."
  (let ((tasks nil))
    (org-map-entries
     (lambda ()
       (let ((data (org-ebs--get-task-data)))
         ;; Only collect incomplete tasks that have a valid effort estimate > 0
         (when (and (> (plist-get data :effort) 0)
                    (not (plist-get data :done?)))
           (push data tasks))))
     t
     'tree)
    tasks))

(defun org-ebs--init-db ()
  "Initialize the native Emacs 29 SQLite database and relational schema."
  (unless (sqlite-available-p)
    (error "Emacs 29+ native SQLite support is required for org-ebs"))
  (setq org-ebs--db (sqlite-open org-ebs-db-file))
  (sqlite-execute
   org-ebs--db
   "CREATE TABLE IF NOT EXISTS ebs_velocities (
      task_id TEXT PRIMARY KEY,
      estimate_minutes INTEGER,
      actual_minutes INTEGER,
      velocity REAL,
      completion_date DATETIME DEFAULT CURRENT_TIMESTAMP
    ) WITHOUT ROWID;")
  ;; Enforce the 6-month temporal decay specified by EBS methodology
  (sqlite-execute
   org-ebs--db
   "DELETE FROM ebs_velocities WHERE completion_date <= datetime('now', '-6 months');"))

(defun org-ebs--insert-velocity (task-id effort actual completion-date)
  "Insert captured data into the SQLite cache.

We only insert values which have non-zero effort and recorded times."
  (when (and (> effort 0) (> actual 0))
    (let ((velocity (/ (float effort) (float actual)))
          (completion (format-time-string "%F %T" completion-date)))
      (sqlite-execute
       org-ebs--db
       "INSERT OR REPLACE INTO ebs_velocities (task_id, estimate_minutes, actual_minutes, velocity, completion_date)
            VALUES (?,?,?,?,?);"
       (list task-id effort actual velocity completion)))))

(defun org-ebs-record-velocity ()
  "Hook function triggered on Org state change to autonomously log velocities."
  ;; Only proceed if the task has entered the DONE state
  (when (org-entry-is-done-p)
    (let* ((data (org-ebs--get-task-data))
           (effort (plist-get data :effort))
           (actual (plist-get data :clocked))
           (closed-time (plist-get data :closed-time))
           (task-id (plist-get data :id)))
      (org-ebs--insert-velocity task-id effort actual closed-time))))

;;;###autoload
(defun org-ebs-ingest-subtree ()
  "Interactively scan the current Org subtree for DONE tasks and log their velocities."
  (interactive)
  (unless org-ebs--db
    (org-ebs--init-db))
  (let ((ingested-count 0))
    (org-map-entries
     (lambda ()
       (let* ((data (org-ebs--get-task-data))
              (effort (plist-get data :effort))
              (done? (plist-get data :done?))
              (actual (plist-get data :clocked))
              (closed-time (plist-get data :closed-time))
              (task-id (plist-get data :id)))
         (when (and done? (org-ebs--insert-velocity task-id effort actual closed-time))
           (cl-incf ingested-count))))
     t
     'tree)
    (message "Successfully ingested %d historical tasks into the EBS database." ingested-count)))

(defun org-ebs--get-historical-velocities ()
  "Query the database for historical velocities or inject a fake history."
  (let ((rows (sqlite-select org-ebs--db "SELECT velocity FROM ebs_velocities;")))
    (if (< (length rows) 5)
        ;; Inject wide-spread fake history if not enough real data exists
        org-ebs-random-velocities
      (mapcar #'car rows))))

(defun org-ebs--run-monte-carlo (tasks iterations)
  "Execute the Monte Carlo simulation across pending TASKS for ITERATIONS."
  (let ((velocities (org-ebs--get-historical-velocities))
        (results nil))
    (dotimes (_ iterations)
      (let ((iteration-total-minutes 0.0))
        (dolist (task tasks)
          (let* ((vel-count (length velocities))
                 ;; Sample a random historical velocity with replacement
                 (rand-vel (nth (random vel-count) velocities))
                 (effort-minutes (plist-get task :effort))
                 ;; Apply velocity coefficient: T_k = E_i / v_rand
                 (simulated-time (/ (float effort-minutes) rand-vel)))
            (cl-incf iteration-total-minutes simulated-time)))
        ;; Push the completed project future to the results array
        (push iteration-total-minutes results)))
    results))

(defun org-ebs--minutes-to-date (total-minutes working-hours)
  "Convert simulated total minutes into an actionable calendar delivery date."
  (let ((remaining-hours (/ total-minutes 60.0))
        (current-date (current-time)))
    (while (> remaining-hours 0)
      ;; Decode the timestamp into calendar segments
      (let* ((decoded (decode-time current-date))
             (dow (nth 6 decoded))) ; Day of Week: 0 = Sun, 6 = Sat
        ;; Decrement remaining hours only on valid working days
        (unless (or (= dow 0) (= dow 6))
          (setq remaining-hours (- remaining-hours working-hours))))
      ;; If hours remain, step the calendar forward by 24 hours
      (when (> remaining-hours 0)
        (setq current-date (time-add current-date (days-to-time 1)))))
    current-date))

(defun org-ebs--calculate-percentiles (dates percentiles)
  "Sort the calendar DATES chronologically and extract standard EBS percentiles."
  (let ((sorted-dates (sort dates #'time-less-p))
        (len (length dates)))
    (mapcar (lambda (p)
              (let ((pdsp (format "%0.0f%%" (* p 100))))
                (list pdsp
                      (nth (floor (* p len)) sorted-dates))))
         percentiles)))

(defun org-dblock-write:ebs-forecast (params)
  "Writer function orchestrating the dynamic block update."
  (let ((iterations (or (plist-get params :iterations) org-ebs-simulation-iterations))
        (confidence-intervals (or (plist-get params :pvals) org-ebs-confidence-intervals))
        (working-hours (or (plist-get params :work-hours) org-ebs-working-hours-per-day))
        (tasks nil))
    (save-excursion
      ;; Navigate to the root of the project to capture the entire scope
      (org-up-heading-safe)
      (org-ebs-ingest-subtree)
      (setq tasks (org-ebs--get-pending-tasks)))

    (if (null tasks)
        (insert "No pending tasks with valid effort estimates found.\n")
      (let* ((sim-results (org-ebs--run-monte-carlo tasks iterations))
             (dates (mapcar (lambda (result) (org-ebs--minutes-to-date result working-hours)) sim-results))
             (percentiles (org-ebs--calculate-percentiles dates confidence-intervals)))

        ;; Construct and insert the native Org mode table
        (insert "| Confidence Level | Projected Completion Date |\n")
        (insert "|--- |--- |\n")
        (dolist (p percentiles)
          (let ((pdsp (car p))
                (pred (cadr p)))
            (insert (format "| %s | %s |\n"
                            pdsp
                            (format-time-string "%Y-%m-%d" pred))))))
      ;; Force Org mode to recalculate column alignments visually
      (org-table-align))))

(provide 'org-dblock-ebs)
;;; org-dblock-ebs.el ends here.
