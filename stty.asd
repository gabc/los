;;;								-*- Lisp -*-
;;; stty.asd -- System definition for stty
;;;

(defsystem stty
    :name               "stty"
    :description        "Show and set terminal settings."
    :version            "0.1.0"
    :author             "Nibby Nebbulous <nibbula -(. @ .)- gmail.com>"
    :license            "GPLv3"
    :source-control	:git
    :long-description   "Show and set terminal settings."
    :depends-on (:dlib :opsys :dlib-misc :char-util)
    :components
    ((:file "stty")))
