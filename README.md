# barlito/symfony-make-rules

This project is meant to be used as a submodule on my Symfony stack to have all the tools I use at hand.

How to use
-------

- Add this repo as a git submodule in your project :

`git submodule add https://github.com/barlito/php-make-rules make`


- To use this project you just need to include the entrypoint.mk file in your own Makefile :
```
# Makefile

# Include all make rules from submodule
include make/entrypoint.mk
```

Description
-------

Make rules are divided in two major sub-categories : App and Stack.

App sub-category include all rules linked directly for your code and your application,
under this category you will find QoL rules for Symfony, Doctrine & Composer
and rules for your code style and your tests.

Stack sub-category contain rules for the installation, Docker QoL rules and
development or production rules aggregations to easily deploy or start your app.

Rules
-------

## App
//ToDo

## Stack
//ToDo
