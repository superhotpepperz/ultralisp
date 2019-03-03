(defpackage #:ultralisp/lfarm/core
  (:use #:cl)
  (:use #:log4cl)
  (:import-from #:log4cl-json)
  (:import-from #:slynk)
  
  (:import-from #:ultralisp/slynk)
  (:import-from #:ultralisp/lfarm/command
                #:task-with-commands
                #:with-commands-processor)
  (:import-from #:lfarm-client)
  (:import-from #:lfarm-server
                #:kill-tasks
                #:+corrupt-stream-flag+
                #:send-object
                #:current-thread
                #:with-tag
                #:socket-close*
                #:with-task-index
                #:read-and-process-task
                #:ignore-errors/log)
  (:import-from #:lfarm-common
                #:socket-stream
                #:unwind-protect/safe
                #:with-errors-logged
                #:receive-object)
  (:import-from #:ultralisp/variables
                #:get-postgres-ro-pass
                #:get-postgres-ro-user
                #:get-postgres-host)
  (:export
   #:submit-task
   #:connect-to-servers))
(in-package ultralisp/lfarm/core)

;; This package contains a patched functions from lfarm-server
;; to be able to quit worker correctly when it processed given
;; number of tasks.
;; We need it to build each version in a clean separate process.

(defvar *after-last-task* nil
  "A function to call when the last task was processed. It could stop or restart the worker, for example.")


(defun task-loop (stream socket)
  (log:info "start task loop" stream (current-thread))
  (let ((num-processed-tasks 0)
        (num-tasks-to-process 1))
    (with-tag :next-task
      (log:info "Reading next task")
      (when (< num-processed-tasks
               num-tasks-to-process)
        (flet ((clean-return (err)
                 (declare (ignore err))
                 (log:info "End task loop" stream)
                 (return-from task-loop))
               (corrupt-handler (err)
                 (log:info "Corrupted stream" err stream)
                 (ignore-errors/log (send-object +corrupt-stream-flag+ stream))
                 (go :next-task))
               (next-task ()
                 "This function will be called to proceed to a new task if current was processed or if some
                  error was raised during it's processing."
                 (incf num-processed-tasks)
                 (go :next-task)))
          
          (read-and-process-task stream
                                 #'clean-return
                                 #'corrupt-handler
                                 #'next-task)
          
          (next-task)))
      
      ;; (when *after-last-task*
      ;;   (funcall *after-last-task*
      ;;            socket))
      )))


(defun respond (message stream socket)
  (ecase message
    (:ping (send-object :pong stream))
    (:task-loop (send-object :in-task-loop stream)
                (with-task-index
                  (task-loop stream socket)))
    (:kill-tasks (kill-tasks (receive-object stream)))))


(defun lfarm-server::call-respond (message socket)
  (with-errors-logged
    (unwind-protect/safe
     :main (respond message (socket-stream socket) socket)
     :cleanup (socket-close* socket))))


(defun on-last-task (socket)
  (log:info "Exiting from task-loop because of tasks limit")

  (force-output (socket-stream socket))
  
  (log:info "Sleeping 5 seconds")
  (sleep 5)
  
  (lfarm-server::socket-close* socket)
  (uiop:quit))


(defun lfarm-common::write-log (level package message &rest args)
  (let ((*package* package))
    (if (string= level
                 "info")
        (log:debug  "lfarm log" message args)
        (log:error "lfarm log" message args))))


(defun quit ()
  (log:info "Quitting by command from master")
  (uiop:quit))


(defun submit-task (func &rest args)
  "Submits a task to one of remote workers and waits for the result."
  (check-type func symbol)
  
  (let ((channel (lfarm:make-channel)))
    (loop
      do (handler-case
             (return-from submit-task
               (with-commands-processor
                 (apply #'lfarm:submit-task* channel
                        'task-with-commands
                        (get-postgres-host)
                        (get-postgres-ro-user)
                        (get-postgres-ro-pass)
                        func args)
                 (prog1 (lfarm:try-receive-result channel :timeout (* 24 60 60))
                   ;; Command worker to quit, because we want it to process only
                   ;; one task and quit, so the next task should not be affected by previous.
                   (lfarm:submit-task* channel 'quit))))
           #+ccl
           (ccl:socket-error ()
             (log:info "Socket error catched, retrying task"))))))


(defun connect-to-servers (&key (servers '(("127.0.0.1" 10100))))
  "This function is for use in the main part of the Ultralisp.
   It will connect to one or many workers which will build versions and run checks."
  (setf lfarm:*kernel* (lfarm:make-kernel servers)))
